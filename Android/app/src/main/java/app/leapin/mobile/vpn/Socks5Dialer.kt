package app.leapin.mobile.vpn

import java.io.BufferedInputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket

/** Connects through a local SOCKS5 proxy, so the tunnel keeps using the app's engine. */
object Socks5Dialer {
    fun connect(proxyPort: Int, host: String, port: Int, timeoutMs: Int = 8_000): Socket {
        val socket = Socket()
        socket.connect(InetSocketAddress("127.0.0.1", proxyPort), timeoutMs)
        socket.soTimeout = timeoutMs
        val output = socket.getOutputStream()
        val input = BufferedInputStream(socket.getInputStream())

        output.write(byteArrayOf(0x05, 0x01, 0x00))
        output.flush()
        val greeting = read(input, 2)
        require(greeting[0].toInt() == 0x05 && greeting[1].toInt() == 0x00) { "socks5: greeting refused" }

        val name = host.toByteArray()
        val request = arrayOf<Byte>(0x05, 0x01, 0x00, 0x03, name.size.toByte()).toByteArray() + name +
            byteArrayOf(((port shr 8) and 0xFF).toByte(), (port and 0xFF).toByte())
        output.write(request)
        output.flush()

        val head = read(input, 4)
        require(head[0].toInt() == 0x05) { "socks5: bad reply" }
        require(head[1].toInt() == 0x00) { "socks5: connect rejected (" + head[1] + ")" }
        when (head[3].toInt() and 0xFF) {
            0x01 -> read(input, 4 + 2)
            0x04 -> read(input, 16 + 2)
            0x03 -> {
                val length = read(input, 1)[0].toInt() and 0xFF
                read(input, length + 2)
            }
            else -> error("socks5: unknown address type " + head[3])
        }
        socket.soTimeout = 0
        return socket
    }

    private fun read(input: InputStream, count: Int): ByteArray {
        val out = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(out, offset, count - offset)
            if (read <= 0) error("socks5: truncated reply")
            offset += read
        }
        return out
    }
}
