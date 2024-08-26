# Goldilocks Hashing

_This article is the latest in a series of posts that discuss evolving functional APIs. The previous post is [Optimizing Functional Walks of File Trees](https://github.com/mpilquist/blog-walks/blob/main/README.md)._

The [fs2-io](https://fs2.io/#/io) library provides support for computing cryptographic hashes, e.g. SHA-256, in a functional way. It provides a single API that works on the JVM, Scala.js, and Scala Native, delegating to the Java Cryptography API, Web Crypto, and OpenSSL respectively.

The `fs2.hash` object provides a pipe for each supported hash function:

```scala
package fs2

object hash {
  def md5[F[_]]: Pipe[F, Byte, Byte] = ???
  def sha1[F[_]]: Pipe[F, Byte, Byte] = ???
  def sha256[F[_]]: Pipe[F, Byte, Byte] = ???
  def sha384[F[_]]: Pipe[F, Byte, Byte] = ???
  def sha512[F[_]]: Pipe[F, Byte, Byte] = ???
}
```

These pipes take a source byte stream and output a new byte stream. Pulling on the output byte stream causes the source to be pulled on and all bytes emitted from the source are added to the hash calculation. Upon termination of the source, the hash is finalized and output as a single chunk.

Computing the hash of a byte stream can be accomplished by sending that source to a hash pipe and collecting the resulting output in to a collection.

```scala mdoc:to-string
import fs2.{Chunk, Pure, Stream, hash}
import scodec.bits.ByteVector

val source: Stream[Pure, Byte] = Stream.chunk(Chunk.array("The quick brown fox".getBytes))
val hashed = source.through(hash.sha256).to(ByteVector)
```

This works equally well for effectful streams -- for example, hashing a file:

```scala mdoc:reset:to-string
import cats.effect.IO
import fs2.{Chunk, Pure, Stream, hash}
import fs2.io.file.{Files, Path}
import scodec.bits.ByteVector

val source: Stream[IO, Byte] = Files[IO].readAll(Path("LICENSE"))
val hashed = source.through(hash.sha256).compile.to(ByteVector)

import cats.effect.unsafe.implicits.global
val result = hashed.unsafeRunSync()
```

The `fs2.hash` API is too simple though. Consider a scenario where you want to write a byte stream to a file *and* write a hash of the same byte stream to another file. Doing each of these transformations in isolation is easy:

```scala mdoc:to-string
def writeToFile[F[_]: Files](source: Stream[F, Byte], path: Path): Stream[F, Nothing] =
  source.through(Files[F].writeAll(path))

def writeHashToFile[F[_]: Files](source: Stream[F, Byte], path: Path): Stream[F, Nothing] =
  source.through(hash.sha256).through(Files[F].writeAll(path))
```

Perhaps the simplest way to combine these functions is via stream composition:

```scala mdoc:to-string
def writeFileAndHash[F[_]: Files](source: Stream[F, Byte], path: Path): Stream[F, Nothing] =
  writeToFile(source, path) ++ writeHashToFile(source, Path(path.toString + ".sha256"))
```

This approach has a major issue though: the source stream is processed twice -- once when writing the file and once when computing the hash. For some sources, this is simply inefficient. Imagine a source stream that originates from another file on the file system. This solution would result in opening that file twice. The inefficiency is worse for streams with lots of computations, as those computations would be run twice as well.

There's a bigger issue though. Some streams aren't safe to be used multiple times -- a stream of bytes from a network socket for instance. Using those streams more than once often result in unexpected results. When streaming from a socket, the bytes received are gone by the time the stream is run a second time. Maybe the second evaluation returns any new bytes received on the socket? Or maybe the socket was closed as an implementation detail of reaching the end of the source stream and the second evaluation results in an error or a hang.

We need a way to process the source stream once and simultaneously write to the output file and compute the hash. The `broadcastThrough` operation on `Stream` directly supports this use case -- it takes one or more pipes as an argument and sends any emitted elements from the source to all of those pipes, collecting their outputs in to a single output stream. 


```scala mdoc:to-string
import cats.effect.Concurrent

def writeFileAndHashViaBroadcast[F[_]: Files: Concurrent](
  source: Stream[F, Byte], path: Path
): Stream[F, Nothing] =
  source.broadcastThrough(
    s => writeToFile(s, path),
    s => writeHashToFile(s, Path(path.toString + ".sha256"))
  )
```

Equivalently, since `broadcastThrough` operates on pipes, we could inline the definitions of `writeToFile` and `writeHashToFile` and simplify a bit, keeping each expression as a pipe:


```scala mdoc:to-string
def writeFileAndHashViaBroadcastPipes[F[_]: Files: Concurrent](
  source: Stream[F, Byte], path: Path
): Stream[F, Nothing] =
  source.broadcastThrough(
    Files[F].writeAll(path),
    hash.sha256 andThen Files[F].writeAll(Path(path.toString + ".sha256"))
  )
```

In either case, we picked up a `Concurrent` constraint, indicating `broadcastThrough` is doing some concurrency. This technique certainly works but it feels a bit overkill. The `broadcastThrough` operator is an example of a scatter-gather algorithm. The chunks from the source stream are scattered to each pipe and the subsequent outputs of those pipes are gathered back in to a single output stream. There's a performance penalty to this this coordination, though if the chunk sizes are sufficiently large then performance is unlikely to be an issue in practice. Still though, it seems like this solution violates the [principle of least power](https://www.lihaoyi.com/post/StrategicScalaStylePrincipleofLeastPower.html#:~:text=If%20your%20function%20only%20needs,can't%20use%20other%20things.). We should be able to compute a hash while processing a byte stream, without introducing complex concurrency constructs.

## Building Blocks

FS2 pipes are completely opaque -- they are simple functions from streams to streams (i.e. `Pipe[F, A, B]` is an alias for `Stream[F, A] => Stream[F, B]`). While this makes for easy composition -- e.g., via `andThen` -- the opacity leaves us little control. We can *only* compose pipes in to larger pipes or apply a source to a pipe, yield an output stream. We can't inspect elements that flow through it or interact with it in any other way. 

The implementation of the hashing pipes we've seen so far is based on observing the chunks of a source stream, updating a running hash computation with each observed chunk, and then emitting the final hash value upon completion of the source. We could model the streaming hash computation with a `Hasher` trait: 

```scala
trait Hasher:
  def update(bytes: Chunk[Byte]): Unit
  def hash: Chunk[Byte]
```

To compute a hash of a stream using this API, we would create a new `Hasher` instance for a desired hash function (more on this in a moment), call `update` for each chunk in the stream, and emit the result of `hash` when the source completes. However, the `Hasher` trait clearly encapsulates some mutable state and hence the methods must have side effects. To make the API referentially transparent, we can parameterize `Hasher` by an effect type:

```scala mdoc:silent
import fs2.{Chunk, Stream}
import cats.effect.IO
```

```scala mdoc:to-string
trait Hasher[F[_]]:
  def update(bytes: Chunk[Byte]): F[Unit]
  def hash: F[Chunk[Byte]]
```

How do we create instances of `Hasher`? We'll need to know the desired hash function at the very lease. We'll also need to suspend over some mutable state, so we could reach for a `Sync` constraint. But we want this to be a general purpose library and we don't want to propagate `Sync` constraints through call sites. Instead, let's introduce a capability trait that allows creation of `Hasher` given a hash algorithm. Then we can provide a constructor for `Hashing[F]` given a `Sync[F]`.

```scala mdoc:to-string
import cats.effect.{Resource, Sync, SyncIO}
import fs2.Pipe

enum HashAlgorithm:
  case SHA1
  case SHA256
  case SHA512
  // etc.

trait Hashing[F[_]]:
  def hasher(algorithm: HashAlgorithm): Resource[F, Hasher[F]]

object Hashing:
  def apply[F[_]](using F: Hashing[F]): F.type = F

  def forSync[F[_]: Sync]: Hashing[F] = new Hashing[F]:
    def hasher(algorithm: HashAlgorithm): Resource[F, Hasher[F]] =
      ??? // Implementation isn't important right now but assume this delegates to platform crypto apis

//  given forIO: Hashing[IO] = forSync[IO] 
//  given forSyncIO: Hashing[SyncIO] = forSync[SyncIO] 
```

The `Hashing[F]` capability trait is a typeclass that allows creation of `Hasher[F]` instances. A new hasher is returned as a `Resource[F, Hasher[F]]`, allowing the implementation to manage initialization and finalization of an instance. This may seem like overkill for a pure function -- afterall, isn't a hash a simple calculation that digests an arbitrary number of bytes in to a fixed size number of bytes? Implementations are free to use operating system resources -- e.g., delegating to a [hardware security module](https://en.wikipedia.org/wiki/Hardware_security_module) and hence abstracting over a communication channel with a hardware device.

Given this new implementation, we can hash a stream in a relatively straightforward fashion:

```scala mdoc:to-string
import cats.effect.MonadCancelThrow

def hashingPipe[F[_]: Hashing: MonadCancelThrow](algorithm: HashAlgorithm): Pipe[F, Byte, Byte] =
  source =>
    Stream.resource(Hashing[F].hasher(algorithm)).flatMap:
      hasher =>
        source.chunks.flatMap(c => Stream.exec(hasher.update(c))) ++ Stream.eval(hasher.hash).unchunks
```
