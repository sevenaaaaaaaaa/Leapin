package app.leapin.mobile.proxy

import java.io.BufferedInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

/**
 * The phone's own proxy: SOCKS5 and HTTP (CONNECT + absolute-form) on loopback.
 *
 * Deliberately free of Android imports so it runs on a plain JVM and can be tested
 * there. The VPN layer (VpnService on Android, NetworkExtension on iOS) is supposed
 * to hand its traffic to something that speaks exactly this.
 */
class ProxyEngine(private val requestedPort: Int = 0) {

    private var server: ServerSocket? = null
    private val running = AtomicInteger(0)
    private val active = AtomicInteger(0)
    private val sessions = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<Socket, Boolean>())

    val port: Int get() = server?.localPort ?: 0
    val isRunning: Boolean get() = server?.isClosed == false
    val activeConnections: Int get() = active.get()

    fun start() {
        if (isRunning) return
        val socket = ServerSocket()
        socket.reuseAddress = true
        socket.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), requestedPort))
        server = socket
        running.set(1)
        Thread {
            while (running.get() == 1) {
                val client = try {
                    socket.accept()
                } catch (_: Throwable) {
                    break
                }
                sessions.add(client)
                active.incrementAndGet()
                Thread { serve(client) }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true; name = "leapin-proxy-accept" }.start()
    }

    fun stop() {
        running.set(0)
        try { server?.close() } catch (_: Throwable) {}
        server = null
        for (socket in sessions) { try { socket.close() } catch (_: Throwable) {} }
        sessions.clear()
        active.set(0)
    }

    private fun serve(client: Socket) {
        try {
            client.soTimeout = 30_000
            val input = BufferedInputStream(client.getInputStream())
            val first = input.read()
            if (first < 0) return
            if (first == 0x05) {
                socks5(client, input, first)
            } else {
                http(client, input, first)
            }
        } catch (_: Throwable) {
            // A client that disappears mid-handshake is normal; nothing to report.
        } finally {
            sessions.remove(client)
            active.decrementAndGet()
            try { client.close() } catch (_: Throwable) {}
        }
    }

    // MARK: - SOCKS5

    private fun socks5(client: Socket, input: InputStream, first: Int) {
        val output = client.getOutputStream()
        val methodCount = readByte(input)
        repeat(methodCount) { readByte(input) }
        output.write(byteArrayOf(0x05, 0x00))
        output.flush()

        readByte(input) // version
        val command = readByte(input)
        readByte(input) // reserved
        val addressType = readByte(input)
        val host = when (addressType) {
            0x01 -> {
                val raw = readFully(input, 4)
                InetAddress.getByAddress(raw).hostAddress ?: return
            }
            0x03 -> {
                val length = readByte(input)
                String(readFully(input, length))
            }
            0x04 -> {
                val raw = readFully(input, 16)
                InetAddress.getByAddress(raw).hostAddress ?: return
            }
            else -> return replyFailure(output, 0x08)
        }
        val port = (readByte(input) shl 8) or readByte(input)
        if (command != 0x01) return replyFailure(output, 0x07)

        val upstream = try {
            Socket().apply { connect(InetSocketAddress(host, port), 10_000); tcpNoDelay = true }
        } catch (_: Throwable) {
            return replyFailure(output, 0x05)
        }
        output.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
        output.flush()
        relay(client, upstream)
    }

    private fun replyFailure(output: OutputStream, code: Int) {
        try {
            output.write(byteArrayOf(0x05, code.toByte(), 0x00, 0x01, 0, 0, 0, 0, 0, 0))
            output.flush()
        } catch (_: Throwable) {}
    }

    // MARK: - HTTP

    private fun http(client: Socket, input: InputStream, first: Int) {
        val head = readHead(input, first) ?: return
        val text = String(head)
        val lines = text.split("\r\n")
        val requestLine = lines.firstOrNull() ?: return
        val parts = requestLine.split(" ")
        if (parts.size < 3) return
        val method = parts[0]
        val target = parts[1]
        val output = client.getOutputStream()

        if (method.equals("CONNECT", ignoreCase = true)) {
            val hostPort = target.substringBefore(" ")
            val host = hostPort.substringBeforeLast(":", hostPort)
            val port = hostPort.substringAfterLast(":", "443").toIntOrNull() ?: 443
            val upstream = try {
                Socket().apply { connect(InetSocketAddress(host, port), 10_000); tcpNoDelay = true }
            } catch (_: Throwable) {
                output.write("HTTP/1.1 502 Bad Gateway\r\n\r\n".toByteArray())
                output.flush()
                return
            }
            output.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
            output.flush()
            relay(client, upstream)
            return
        }

        // Absolute-form: GET http://host/path HTTP/1.1
        val uri = try { java.net.URI(target) } catch (_: Throwable) { null }
        val host = uri?.host
        if (uri == null || host == null) {
            output.write("HTTP/1.1 400 Bad Request\r\n\r\n".toByteArray())
            output.flush()
            return
        }
        val port = if (uri.port > 0) uri.port else 80
        val upstream = try {
            Socket().apply { connect(InetSocketAddress(host, port), 10_000); tcpNoDelay = true }
        } catch (_: Throwable) {
            output.write("HTTP/1.1 502 Bad Gateway\r\n\r\n".toByteArray())
            output.flush()
            return
        }
        val path = (if (uri.rawPath.isNullOrEmpty()) "/" else uri.rawPath) +
                (uri.rawQuery?.let { "?$it" } ?: "")
        val forwarded = StringBuilder()
        forwarded.append("$method $path HTTP/1.1\r\n")
        for (line in lines.drop(1)) {
            if (line.isEmpty()) continue
            val lower = line.lowercase()
            if (lower.startsWith("proxy-connection:") || lower.startsWith("proxy-authorization:")) continue
            forwarded.append(line).append("\r\n")
        }
        forwarded.append("\r\n")
        upstream.getOutputStream().write(forwarded.toString().toByteArray())
        upstream.getOutputStream().flush()
        relay(client, upstream)
    }

    /** Reads request line + headers, ending at the blank line. */
    private fun readHead(input: InputStream, first: Int): ByteArray? {
        val buffer = java.io.ByteArrayOutputStream()
        buffer.write(first)
        var matched = 0
        val terminator = byteArrayOf(13, 10, 13, 10)
        while (true) {
            val value = input.read()
            if (value < 0) return null
            buffer.write(value)
            matched = if (value.toByte() == terminator[matched]) matched + 1 else if (value == 13) 1 else 0
            if (matched == terminator.size) return buffer.toByteArray()
            if (buffer.size() > 64 * 1024) return null
        }
    }

    private fun relay(client: Socket, upstream: Socket) {
        val forward = Thread { pump(client.getInputStream(), upstream.getOutputStream()); halfClose(upstream) }
        forward.isDaemon = true
        forward.start()
        pump(upstream.getInputStream(), client.getOutputStream())
        halfClose(client)
        try { forward.join(5_000) } catch (_: Throwable) {}
        try { upstream.close() } catch (_: Throwable) {}
        try { client.close() } catch (_: Throwable) {}
    }

    private fun pump(from: InputStream, to: OutputStream) {
        val buffer = ByteArray(16 * 1024)
        try {
            while (true) {
                val read = from.read(buffer)
                if (read <= 0) break
                to.write(buffer, 0, read)
                to.flush()
            }
        } catch (_: Throwable) {
        }
    }

    private fun halfClose(socket: Socket) {
        try { socket.shutdownOutput() } catch (_: Throwable) {}
    }

    private fun readByte(input: InputStream): Int {
        val value = input.read()
        if (value < 0) throw java.io.EOFException("proxy handshake truncated")
        return value
    }

    private fun readFully(input: InputStream, count: Int): ByteArray {
        val out = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(out, offset, count - offset)
            if (read <= 0) throw java.io.EOFException("proxy handshake truncated")
            offset += read
        }
        return out
    }
}
