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

These pipes take a source byte stream and output a new byte stream. Pulling on the output byte stream causes the source to be pulled on, and all the emitted bytes to be hashed. Upon termination of the source, the hash is finalized and output as a single chunk.

```scala mdoc:to-string
import fs2.{Chunk, Pure, Stream}
import fs2.hash
import scodec.bits.ByteVector

val source: Stream[Pure, Byte] = Stream.chunk(Chunk.array("The quick brown fox".getBytes))
val hashed = source.through(hash.sha256).to(ByteVector)
```
