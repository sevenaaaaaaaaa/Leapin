package app.leapin.mobile.vpn

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap

/**
 * UDP half of the tunnel: one connected datagram socket per flow.
 *
 * The engine speaks SOCKS5 TCP only, so UDP goes out DIRECT for now, which matches
 * the router (everything is DIRECT). When rules arrive this is the place that has to
 * consult them first, or speak SOCKS5 UDP ASSOCIATE.
 */
class TunUdpRelay {

    private data class Key(val sourceIp: Long, val sourcePort: Int, val destinationIp: Long, val destinationPort: Int)

    private class Flow(val key: Key, val socket: DatagramSocket) {
        @Volatile var lastUsed = System.currentTimeMillis()
        @Volatile var closed = false
    }

    @Volatile var emit: ((ByteArray) -> Unit)? = null

    private val flows = ConcurrentHashMap<Key, Flow>()
    private val idleMs = 120_000L
    private var sweeper: Thread? = null

    val activeFlows: Int get() = flows.size

    fun start() {
        sweeper = Thread {
            while (true) {
                try { Thread.sleep(30_000) } catch (_: InterruptedException) { return@Thread }
                val cutoff = System.currentTimeMillis() - idleMs
                for ((key, flow) in flows) {
                    if (flow.lastUsed < cutoff) {
                        flow.closed = true
                        try { flow.socket.close() } catch (_: Throwable) {}
                        flows.remove(key)
                    }
                }
            }
        }.apply { isDaemon = true; name = "leapin-udp-sweep" }
        sweeper?.start()
    }

    fun stop() {
        sweeper?.interrupt()
        sweeper = null
        for ((key, flow) in flows) {
            flow.closed = true
            try { flow.socket.close() } catch (_: Throwable) {}
            flows.remove(key)
        }
    }

    fun handle(packet: ByteArray, length: Int) {
        val parsed = parse(packet, length) ?: return
        val key = Key(parsed.sourceIp, parsed.sourcePort, parsed.destinationIp, parsed.destinationPort)
        val existing = flows[key]
        if (existing != null) {
            existing.lastUsed = System.currentTimeMillis()
            try {
                existing.socket.send(DatagramPacket(parsed.payload, parsed.payload.size))
            } catch (_: Throwable) {}
            return
        }
        open(key, parsed)
    }

    private fun open(key: Key, parsed: Datagram) {
        try {
            val socket = DatagramSocket()
            socket.connect(InetAddress.getByAddress(ipBytes(key.destinationIp)), key.destinationPort)
            val flow = Flow(key, socket)
            flows[key] = flow
            socket.send(DatagramPacket(parsed.payload, parsed.payload.size))

            Thread {
                val buffer = ByteArray(65_535)
                while (!flow.closed) {
                    val datagram = DatagramPacket(buffer, buffer.size)
                    try {
                        socket.receive(datagram)
                    } catch (_: Throwable) {
                        break
                    }
                    flow.lastUsed = System.currentTimeMillis()
                    emit?.invoke(build(key, buffer.copyOfRange(0, datagram.length)))
                }
                flows.remove(key, flow)
            }.apply { isDaemon = true; name = "leapin-udp-flow" }.start()
        } catch (_: Throwable) {
            flows.remove(key)
        }
    }

    // MARK: - Packet building

    private fun build(key: Key, payload: ByteArray): ByteArray {
        val total = 20 + 8 + payload.size
        val packet = ByteArray(total)
        packet[0] = 0x45
        packet[2] = ((total shr 8) and 0xFF).toByte()
        packet[3] = (total and 0xFF).toByte()
        packet[6] = 0x40
        packet[8] = 64
        packet[9] = 17
        putInt(packet, 12, key.destinationIp)
        putInt(packet, 16, key.sourceIp)
        packet[20] = ((key.destinationPort shr 8) and 0xFF).toByte()
        packet[21] = (key.destinationPort and 0xFF).toByte()
        packet[22] = ((key.sourcePort shr 8) and 0xFF).toByte()
        packet[23] = (key.sourcePort and 0xFF).toByte()
        packet[24] = (((8 + payload.size) shr 8) and 0xFF).toByte()
        packet[25] = ((8 + payload.size) and 0xFF).toByte()
        System.arraycopy(payload, 0, packet, 28, payload.size)
        val checksum = ipChecksum(packet)
        packet[10] = ((checksum shr 8) and 0xFF).toByte()
        packet[11] = (checksum and 0xFF).toByte()
        return packet
    }

    private fun putInt(target: ByteArray, offset: Int, value: Long) {
        target[offset] = ((value shr 24) and 0xFF).toByte()
        target[offset + 1] = ((value shr 16) and 0xFF).toByte()
        target[offset + 2] = ((value shr 8) and 0xFF).toByte()
        target[offset + 3] = (value and 0xFF).toByte()
    }

    private fun ipChecksum(packet: ByteArray): Int {
        var sum = 0
        var index = 0
        while (index + 1 < 20) {
            sum += ((packet[index].toInt() and 0xFF) shl 8) or (packet[index + 1].toInt() and 0xFF)
            index += 2
        }
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    private fun ipBytes(value: Long): ByteArray = byteArrayOf(
        ((value shr 24) and 0xFF).toByte(),
        ((value shr 16) and 0xFF).toByte(),
        ((value shr 8) and 0xFF).toByte(),
        (value and 0xFF).toByte(),
    )

    // MARK: - Parsing

    private class Datagram(val sourceIp: Long, val destinationIp: Long,
                           val sourcePort: Int, val destinationPort: Int, val payload: ByteArray)

    private fun parse(packet: ByteArray, length: Int): Datagram? {
        if (length < 28) return null
        if (((packet[0].toInt() shr 4) and 0x0F) != 4) return null
        val headerLength = (packet[0].toInt() and 0x0F) * 4
        if (headerLength < 20) return null
        if ((packet[9].toInt() and 0xFF) != 17) return null
        val totalLength = ((packet[2].toInt() and 0xFF) shl 8) or (packet[3].toInt() and 0xFF)
        if (totalLength < headerLength + 8 || totalLength > length) return null
        val udpOffset = headerLength
        val sourcePort = ((packet[udpOffset].toInt() and 0xFF) shl 8) or (packet[udpOffset + 1].toInt() and 0xFF)
        val destinationPort = ((packet[udpOffset + 2].toInt() and 0xFF) shl 8) or (packet[udpOffset + 3].toInt() and 0xFF)
        val udpLength = ((packet[udpOffset + 4].toInt() and 0xFF) shl 8) or (packet[udpOffset + 5].toInt() and 0xFF)
        if (udpLength < 8 || udpOffset + udpLength > totalLength) return null
        val payload = packet.copyOfRange(udpOffset + 8, udpOffset + udpLength)
        return Datagram(readInt(packet, 12), readInt(packet, 16), sourcePort, destinationPort, payload)
    }

    private fun readInt(data: ByteArray, offset: Int): Long {
        return ((data[offset].toLong() and 0xFF) shl 24) or
            ((data[offset + 1].toLong() and 0xFF) shl 16) or
            ((data[offset + 2].toLong() and 0xFF) shl 8) or
            (data[offset + 3].toLong() and 0xFF)
    }
}
