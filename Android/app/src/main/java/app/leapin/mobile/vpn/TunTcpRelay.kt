package app.leapin.mobile.vpn

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

/**
 * Terminates TCP from the TUN and carries each flow over a proxy socket.
 *
 * The virtual interface is lossless and ordered, so this stays deliberately simple:
 * no retransmission, no congestion control, one MSS, an ack for every segment. Port
 * of the Swift TunTCPRelay, so both ends behave the same.
 */
class TunTcpRelay(private val connector: (String, Int) -> Socket) {

    private data class Key(val sourceIp: Long, val sourcePort: Int, val destinationIp: Long, val destinationPort: Int)

    private class Flow(val key: Key, var ourSequence: Long, var theirSequence: Long) {
        var socket: Socket? = null
        val pending = ByteArrayOutputStream()
    }

    /** Where packets go back to the TUN. */
    @Volatile var emit: ((ByteArray) -> Unit)? = null

    private val flows = ConcurrentHashMap<Key, Flow>()
    private val mss = 1400

    val activeFlows: Int get() = flows.size

    fun handle(packet: ByteArray, length: Int) {
        val parsed = parse(packet, length) ?: return
        if (parsed.protocol != 6) return
        val tcp = parsed.tcp ?: return

        val key = Key(parsed.sourceIp, tcp.sourcePort, parsed.destinationIp, tcp.destinationPort)

        if (tcp.isSyn && !tcp.isAck) {
            open(key, tcp)
            return
        }

        val flow = flows[key]
        if (flow == null) {
            if (!tcp.isRst) {
                send(build(key, tcp.acknowledgement, (tcp.sequence + tcp.payload.size) and 0xFFFFFFFFL, FLAG_RST, ByteArray(0)))
            }
            return
        }

        if (tcp.payload.isNotEmpty()) {
            flow.theirSequence = (tcp.sequence + tcp.payload.size) and 0xFFFFFFFFL
            send(build(flow, flow.ourSequence, flow.theirSequence, FLAG_ACK, ByteArray(0)))
            val socket = flow.socket
            if (socket != null) {
                try {
                    socket.getOutputStream().write(tcp.payload)
                    socket.getOutputStream().flush()
                } catch (_: Throwable) {
                    close(flow, fin = false, reset = true)
                }
            } else {
                synchronized(flow.pending) { flow.pending.write(tcp.payload) }
            }
        }

        if (tcp.isFin) {
            flow.theirSequence = (flow.theirSequence + 1) and 0xFFFFFFFFL
            send(build(flow, flow.ourSequence, flow.theirSequence, FLAG_ACK, ByteArray(0)))
            close(flow, fin = true, reset = false)
        }
    }

    private fun open(key: Key, syn: TcpView) {
        val initial = (System.nanoTime() and 0x3FFFFFFF)
        val flow = Flow(key, initial, (syn.sequence + 1) and 0xFFFFFFFFL)
        flows[key] = flow
        send(build(flow, initial, flow.theirSequence, FLAG_SYN or FLAG_ACK, ByteArray(0)))
        flow.ourSequence = (initial + 1) and 0xFFFFFFFFL

        val host = ipString(key.destinationIp)
        val port = key.destinationPort
        Thread {
            try {
                val socket = connector(host, port)
                socket.tcpNoDelay = true
                flow.socket = socket
                val early = synchronized(flow.pending) {
                    val bytes = flow.pending.toByteArray()
                    flow.pending.reset()
                    bytes
                }
                if (early.isNotEmpty()) {
                    socket.getOutputStream().write(early)
                    socket.getOutputStream().flush()
                }
                readLoop(flow, socket)
            } catch (_: Throwable) {
                close(flow, fin = false, reset = true)
            }
        }.apply { isDaemon = true; name = "leapin-flow" }.start()
    }

    private fun readLoop(flow: Flow, socket: Socket) {
        val buffer = ByteArray(mss)
        try {
            val input: InputStream = socket.getInputStream()
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                sendData(flow, buffer, read)
            }
        } catch (_: Throwable) {
        }
        close(flow, fin = true, reset = false)
    }

    private fun sendData(flow: Flow, data: ByteArray, length: Int) {
        var offset = 0
        while (offset < length) {
            val size = minOf(mss, length - offset)
            val slice = data.copyOfRange(offset, offset + size)
            send(build(flow, flow.ourSequence, flow.theirSequence, FLAG_ACK or FLAG_PSH, slice))
            flow.ourSequence = (flow.ourSequence + size) and 0xFFFFFFFFL
            offset += size
        }
    }

    private fun close(flow: Flow, fin: Boolean, reset: Boolean) {
        if (flows.remove(flow.key) == null) return
        if (reset) {
            send(build(flow, flow.ourSequence, flow.theirSequence, FLAG_RST, ByteArray(0)))
        } else if (fin) {
            send(build(flow, flow.ourSequence, flow.theirSequence, FLAG_FIN or FLAG_ACK, ByteArray(0)))
            flow.ourSequence = (flow.ourSequence + 1) and 0xFFFFFFFFL
        }
        try { flow.socket?.close() } catch (_: Throwable) {}
    }

    private fun send(packet: ByteArray) { emit?.invoke(packet) }

    // MARK: - Building

    private fun build(flow: Flow, sequence: Long, acknowledgement: Long, flags: Int, payload: ByteArray): ByteArray {
        return build(flow.key, sequence, acknowledgement, flags, payload)
    }

    private fun build(key: Key, sequence: Long, acknowledgement: Long, flags: Int, payload: ByteArray): ByteArray {
        val total = 20 + 20 + payload.size
        val packet = ByteArray(total)
        packet[0] = 0x45
        packet[2] = ((total shr 8) and 0xFF).toByte()
        packet[3] = (total and 0xFF).toByte()
        packet[6] = 0x40
        packet[8] = 64
        packet[9] = 6
        putInt(packet, 12, key.destinationIp) // reply source is the tunnel address
        putInt(packet, 16, key.sourceIp)
        // TCP
        packet[20] = ((key.destinationPort shr 8) and 0xFF).toByte()
        packet[21] = (key.destinationPort and 0xFF).toByte()
        packet[22] = ((key.sourcePort shr 8) and 0xFF).toByte()
        packet[23] = (key.sourcePort and 0xFF).toByte()
        putInt(packet, 24, sequence)
        putInt(packet, 28, acknowledgement)
        packet[32] = 0x50
        packet[33] = flags.toByte()
        packet[34] = 0xFF.toByte(); packet[35] = 0xFF.toByte()
        System.arraycopy(payload, 0, packet, 40, payload.size)
        val tcpChecksum = checksum(packet, 20, total - 20, key.destinationIp, key.sourceIp, 6)
        packet[36] = ((tcpChecksum shr 8) and 0xFF).toByte()
        packet[37] = (tcpChecksum and 0xFF).toByte()
        val ipChecksum = checksum(packet, 0, 20, 0, 0, 0)
        packet[10] = ((ipChecksum shr 8) and 0xFF).toByte()
        packet[11] = (ipChecksum and 0xFF).toByte()
        return packet
    }

    private fun putInt(target: ByteArray, offset: Int, value: Long) {
        target[offset] = ((value shr 24) and 0xFF).toByte()
        target[offset + 1] = ((value shr 16) and 0xFF).toByte()
        target[offset + 2] = ((value shr 8) and 0xFF).toByte()
        target[offset + 3] = (value and 0xFF).toByte()
    }

    private fun checksum(data: ByteArray, offset: Int, length: Int,
                         sourceIp: Long, destinationIp: Long, protocol: Int): Int {
        var sum = 0L
        if (protocol != 0) {
            sum += (sourceIp shr 16) and 0xFFFFL; sum += sourceIp and 0xFFFFL
            sum += (destinationIp shr 16) and 0xFFFFL; sum += destinationIp and 0xFFFFL
            sum += protocol.toLong()
            sum += length.toLong()
        }
        var index = offset
        val end = offset + length
        while (index + 1 < end) {
            sum += (((data[index].toInt() and 0xFF) shl 8) or (data[index + 1].toInt() and 0xFF)).toLong()
            index += 2
        }
        if (index < end) sum += ((data[index].toInt() and 0xFF) shl 8).toLong()
        while (sum shr 16 != 0L) sum = (sum and 0xFFFFL) + (sum shr 16)
        return (sum.inv() and 0xFFFFL).toInt()
    }

    // MARK: - Parsing

    private class TcpView(val sourcePort: Int, val destinationPort: Int,
                          val sequence: Long, val acknowledgement: Long,
                          val flags: Int, val payload: ByteArray) {
        val isSyn get() = flags and FLAG_SYN != 0
        val isAck get() = flags and FLAG_ACK != 0
        val isFin get() = flags and FLAG_FIN != 0
        val isRst get() = flags and FLAG_RST != 0
    }

    private class Parsed(val sourceIp: Long, val destinationIp: Long, val protocol: Int, val tcp: TcpView?)

    private fun parse(packet: ByteArray, length: Int): Parsed? {
        if (length < 20) return null
        if (((packet[0].toInt() shr 4) and 0x0F) != 4) return null
        val headerLength = (packet[0].toInt() and 0x0F) * 4
        if (headerLength < 20 || length < headerLength + 20) return null
        val totalLength = ((packet[2].toInt() and 0xFF) shl 8) or (packet[3].toInt() and 0xFF)
        if (totalLength < headerLength + 20 || totalLength > length) return null
        val sourceIp = readInt(packet, 12)
        val destinationIp = readInt(packet, 16)
        val protocol = packet[9].toInt() and 0xFF
        if (protocol != 6) return Parsed(sourceIp, destinationIp, protocol, null)
        val tcpOffset = headerLength
        val sourcePort = ((packet[tcpOffset].toInt() and 0xFF) shl 8) or (packet[tcpOffset + 1].toInt() and 0xFF)
        val destinationPort = ((packet[tcpOffset + 2].toInt() and 0xFF) shl 8) or (packet[tcpOffset + 3].toInt() and 0xFF)
        val sequence = readInt(packet, tcpOffset + 4)
        val acknowledgement = readInt(packet, tcpOffset + 8)
        val tcpHeaderLength = ((packet[tcpOffset + 12].toInt() shr 4) and 0x0F) * 4
        val flags = packet[tcpOffset + 13].toInt() and 0xFF
        if (tcpHeaderLength < 20 || totalLength < tcpOffset + tcpHeaderLength) return null
        val payload = packet.copyOfRange(tcpOffset + tcpHeaderLength, totalLength)
        return Parsed(sourceIp, destinationIp, protocol,
            TcpView(sourcePort, destinationPort, sequence, acknowledgement, flags, payload))
    }

    private fun readInt(data: ByteArray, offset: Int): Long {
        return ((data[offset].toLong() and 0xFF) shl 24) or
            ((data[offset + 1].toLong() and 0xFF) shl 16) or
            ((data[offset + 2].toLong() and 0xFF) shl 8) or
            (data[offset + 3].toLong() and 0xFF)
    }

    companion object {
        const val FLAG_FIN = 0x01
        const val FLAG_SYN = 0x02
        const val FLAG_RST = 0x04
        const val FLAG_PSH = 0x08
        const val FLAG_ACK = 0x10

        fun ipString(value: Long): String {
            return listOf((value shr 24) and 0xFF, (value shr 16) and 0xFF,
                          (value shr 8) and 0xFF, value and 0xFF).joinToString(".")
        }
    }
}
