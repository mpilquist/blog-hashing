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

This solution has a few major disadvantages:
- the source stream is processed twice -- once when writing the file and once when computing the hash
