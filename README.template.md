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

In either case, we picked up a `Concurrent` constraint, indicating `broadcastThrough` is doing some concurrency.
