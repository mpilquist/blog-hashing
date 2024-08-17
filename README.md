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

```scala
import fs2.{Chunk, Pure, Stream, hash}
import scodec.bits.ByteVector

val source: Stream[Pure, Byte] = Stream.chunk(Chunk.array("The quick brown fox".getBytes))
// source: Stream[Pure, Byte] = Stream(..)
val hashed = source.through(hash.sha256).to(ByteVector)
// hashed: ByteVector = ByteVector(32 bytes, 0x5cac4f980fedc3d3f1f99b4be3472c9b30d56523e632d151237ec9309048bda9)
```

This works equally well for effectful streams -- for example, hashing a file:

```scala
import cats.effect.IO
import fs2.{Chunk, Pure, Stream, hash}
import fs2.io.file.{Files, Path}
import scodec.bits.ByteVector

val source: Stream[IO, Byte] = Files[IO].readAll(Path("LICENSE"))
// source: Stream[[A >: Nothing <: Any] => IO[A], Byte] = Stream(..)
val hashed = source.through(hash.sha256).compile.to(ByteVector)
// hashed: IO[Out] = IO(...)

import cats.effect.unsafe.implicits.global
val result = hashed.unsafeRunSync()
// result: ByteVector = ByteVector(32 bytes, 0x0e8b76ea2b69ae6f3482c7136c3d092ca0c6f5d4480a46b6b01f6bb8ed7d7d9b)
```

The `fs2.hash` API is too simple though. Consider a scenario where you want to write a byte stream to a file *and* write a hash of the same byte stream to another file. Doing each of these transformations in isolation is easy:

```scala
def writeToFile[F[_]: Files](source: Stream[F, Byte], path: Path): Stream[F, Nothing] =
  source.through(Files[F].writeAll(path))

def writeHashToFile[F[_]: Files](source: Stream[F, Byte], path: Path): Stream[F, Nothing] =
  source.through(hash.sha256).through(Files[F].writeAll(path))
```

Perhaps the simplest way to combine these functions is via stream composition:

```scala
def writeFileAndHash[F[_]: Files](source: Stream[F, Byte], path: Path): Stream[F, Nothing] =
  writeToFile(source, path) ++ writeHashToFile(source, Path(path.toString + ".sha256"))
```

This solution has a few major disadvantages:
- the source stream is processed twice -- once when writing the file and once when computing the hash
