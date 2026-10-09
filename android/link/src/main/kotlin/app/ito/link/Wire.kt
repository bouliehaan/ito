package app.ito.link

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.OutputStream
import java.net.Socket

/** Every message on the socket: u16 big-endian length, then that many bytes. */
object Wire {
    const val MAX = 65535

    fun write(out: OutputStream, msg: ByteArray) {
        require(msg.size <= MAX) { "frame too large: ${msg.size}" }
        val buf = ByteArray(2 + msg.size)
        buf[0] = (msg.size ushr 8).toByte()
        buf[1] = msg.size.toByte()
        System.arraycopy(msg, 0, buf, 2, msg.size)
        out.write(buf)
        out.flush()
    }

    fun read(input: DataInputStream): ByteArray {
        val len = try {
            input.readUnsignedShort()
        } catch (e: EOFException) {
            throw EOFException("peer closed")
        }
        return ByteArray(len).also(input::readFully)
    }
}

/** Plaintext kinds inside an encrypted transport message. */
object Kind {
    const val JSON = 1
    const val AUDIO = 2
}

/**
 * One encrypted channel. Writes are serialized (the nonce order must match
 * the byte order on the socket); reads belong to a single reader thread.
 */
class Channel internal constructor(
    private val socket: Socket,
    // The same buffered streams the handshake used: a fresh buffer here would
    // drop anything the first one had already read ahead.
    private val input: DataInputStream,
    private val out: BufferedOutputStream,
    private val transport: Transport,
    val remoteStatic: ByteArray,
    val handshakeHash: ByteArray,
    val remoteHello: JSONObject,
) {
    private val writeLock = Any()

    val remoteAddress: String get() = socket.inetAddress?.hostAddress ?: "?"

    fun send(kind: Int, body: ByteArray) {
        val pt = ByteArray(1 + body.size)
        pt[0] = kind.toByte()
        System.arraycopy(body, 0, pt, 1, body.size)
        synchronized(writeLock) { Wire.write(out, transport.seal(pt)) }
    }

    fun sendJson(obj: JSONObject) = send(Kind.JSON, obj.toString().toByteArray(Charsets.UTF_8))

    /** Blocks. Returns the kind and the body. Throws on a closed socket or a bad tag. */
    fun receive(): Pair<Int, ByteArray> {
        val pt = transport.open(Wire.read(input))
        require(pt.isNotEmpty()) { "empty frame" }
        return (pt[0].toInt() and 0xff) to pt.copyOfRange(1, pt.size)
    }

    fun setReadTimeout(ms: Int) = runCatching { socket.soTimeout = ms }.let { }

    fun close() = runCatching { socket.close() }.let { }

    companion object {
        /** Phone side. Runs XX as responder; nothing is trusted yet — the caller decides. */
        fun accept(socket: Socket, static: DhKey, hello: JSONObject): Channel {
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.tcpNoDelay = true
            val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 16384))
            val out = BufferedOutputStream(socket.getOutputStream(), 16384)
            val hs = XXHandshake(initiator = false, s = static)
            hs.readMessage(Wire.read(input))
            Wire.write(out, hs.writeMessage(hello.toString().toByteArray()))
            val remoteHello = JSONObject(String(hs.readMessage(Wire.read(input)), Charsets.UTF_8))
            socket.soTimeout = 0
            return Channel(socket, input, out, hs.split(), hs.remoteStatic!!, hs.handshakeHash, remoteHello)
        }

        /** Mac side, used by tests and tools on the JVM. The real Mac client is Swift. */
        fun connect(socket: Socket, static: DhKey, hello: JSONObject): Channel {
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.tcpNoDelay = true
            val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 16384))
            val out = BufferedOutputStream(socket.getOutputStream(), 16384)
            val hs = XXHandshake(initiator = true, s = static)
            Wire.write(out, hs.writeMessage())
            val remoteHello = JSONObject(String(hs.readMessage(Wire.read(input)), Charsets.UTF_8))
            Wire.write(out, hs.writeMessage(hello.toString().toByteArray()))
            socket.soTimeout = 0
            return Channel(socket, input, out, hs.split(), hs.remoteStatic!!, hs.handshakeHash, remoteHello)
        }

        private const val HANDSHAKE_TIMEOUT_MS = 10_000
    }
}
