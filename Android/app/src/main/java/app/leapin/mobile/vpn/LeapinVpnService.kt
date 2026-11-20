package app.leapin.mobile.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.leapin.mobile.LocalProxy
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * System-level capture.
 *
 * DNS always goes through this service. TCP goes through it too when the caller asks
 * for a full tunnel: packets are handed to TunTcpRelay, which ends each flow and
 * carries it over SOCKS5 to the app's own engine, so rules and outbounds stay in one
 * place. Non-DNS UDP is not relayed yet; with the full tunnel on, those packets are
 * dropped and apps fall back to TCP.
 *
 * Loading nothing here needs a special entitlement - unlike iOS, a sideloaded APK can
 * run this.
 */
class LeapinVpnService : VpnService() {

    companion object {
        const val ACTION_START = "app.leapin.mobile.vpn.START"
        const val ACTION_STOP = "app.leapin.mobile.vpn.STOP"
        const val EXTRA_FULL_TUNNEL = "fullTunnel"
        private const val CHANNEL = "leapin-vpn"
        private const val NOTIFICATION_ID = 41
        private const val TUN_ADDRESS = "10.111.0.2"
        private const val DNS_SERVER = "10.111.0.1"

        var isRunning by mutableStateOf(false)
            private set
        var isFullTunnel by mutableStateOf(false)
            private set
        var queriesHandled by mutableStateOf(0)
            private set
        var tcpFlows by mutableStateOf(0)
            private set
        var lastQuery by mutableStateOf<String?>(null)
            private set
        var lastError by mutableStateOf<String?>(null)
            private set
    }

    private var tun: ParcelFileDescriptor? = null
    private var thread: Thread? = null
    private var relay: TunTcpRelay? = null
    private var udpRelay: TunUdpRelay? = null
    private var output: FileOutputStream? = null
    @Volatile private var running = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
            else -> startTunnel(intent?.getBooleanExtra(EXTRA_FULL_TUNNEL, false) == true)
        }
        return START_STICKY
    }

    private fun startTunnel(fullTunnel: Boolean) {
        if (running) return
        try {
            if (!LocalProxy.isRunning) LocalProxy.start()
            if (!LocalProxy.isRunning) {
                lastError = LocalProxy.lastError ?: "本机引擎没有启动，TCP 无法接管"
                stopSelf()
                return
            }

            val builder = Builder()
                .setSession("Leapin")
                .setMtu(1500)
                .addAddress(TUN_ADDRESS, 32)
                .addDnsServer(DNS_SERVER)
                .addRoute(DNS_SERVER, 32)
            if (fullTunnel) builder.addRoute("0.0.0.0", 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

            val descriptor = builder.establish()
            if (descriptor == null) {
                lastError = "系统拒绝了 VPN 授权"
                stopSelf()
                return
            }
            tun = descriptor
            output = FileOutputStream(descriptor.fileDescriptor)
            running = true
            isRunning = true
            isFullTunnel = fullTunnel
            lastError = null

            if (fullTunnel) {
                val enginePort = LocalProxy.port
                relay = TunTcpRelay { host, port -> Socks5Dialer.connect(enginePort, host, port) }
                    .also { instance ->
                        instance.emit = { packet ->
                            try {
                                output?.write(packet)
                                tcpFlows = instance.activeFlows
                            } catch (_: Throwable) {
                            }
                        }
                    }
            }

            val udp = TunUdpRelay()
            udp.emit = { packet ->
                try {
                    output?.write(packet)
                } catch (_: Throwable) {
                }
            }
            udp.start()
            udpRelay = udp

            notifyForeground(fullTunnel)
            val worker = Thread { loop(descriptor) }.apply { isDaemon = true; name = "leapin-vpn" }
            thread = worker
            worker.start()
        } catch (error: Throwable) {
            lastError = error.message ?: "无法建立 VPN"
            stopTunnel()
        }
    }

    private fun loop(descriptor: ParcelFileDescriptor) {
        val input = FileInputStream(descriptor.fileDescriptor)
        val buffer = ByteArray(32_767)
        while (running) {
            val length = try { input.read(buffer) } catch (_: Throwable) { break }
            if (length <= 0) continue
            try {
                val protocol = if (length > 9) buffer[9].toInt() and 0xFF else -1
                when (protocol) {
                    17 -> {
                        // Port 53 keeps its own path so the card can show what it
                        // answered; every other datagram is relayed as a flow.
                        val destinationPort = if (length > 24) {
                            ((buffer[headerOffset(buffer, length) + 2].toInt() and 0xFF) shl 8) or
                                (buffer[headerOffset(buffer, length) + 3].toInt() and 0xFF)
                        } else 0
                        if (destinationPort == 53) handleDnsQuery(buffer, length)
                        else udpRelay?.handle(buffer, length)
                    }
                    6 -> relay?.handle(buffer, length)
                    else -> Unit
                }
            } catch (_: Throwable) {
                // A malformed packet is dropped; the tunnel keeps running.
            }
        }
    }

    private fun headerOffset(packet: ByteArray, length: Int): Int {
        if (length < 20) return 20
        val headerLength = (packet[0].toInt() and 0x0F) * 4
        return if (headerLength in 20..length) headerLength else 20
    }

    /** IPv4 + UDP only, destination port 53. Everything else is ignored. */
    private fun handleDnsQuery(packet: ByteArray, length: Int) {
        if (length < 28) return
        val version = (packet[0].toInt() shr 4) and 0x0F
        if (version != 4) return
        val headerLength = (packet[0].toInt() and 0x0F) * 4
        if (headerLength < 20 || length < headerLength + 8) return
        val protocol = packet[9].toInt() and 0xFF
        if (protocol != 17) return

        val sourceIp = packet.copyOfRange(12, 16)
        val destIp = packet.copyOfRange(16, 20)
        val sourcePort = ((packet[headerLength].toInt() and 0xFF) shl 8) or (packet[headerLength + 1].toInt() and 0xFF)
        val destPort = ((packet[headerLength + 2].toInt() and 0xFF) shl 8) or (packet[headerLength + 3].toInt() and 0xFF)
        if (destPort != 53) return

        val udpLength = ((packet[headerLength + 4].toInt() and 0xFF) shl 8) or (packet[headerLength + 5].toInt() and 0xFF)
        val payloadOffset = headerLength + 8
        val payloadLength = minOf(udpLength - 8, length - payloadOffset)
        if (payloadLength <= 0) return
        val query = packet.copyOfRange(payloadOffset, payloadOffset + payloadLength)

        lastQuery = dnsQuestionName(query) ?: lastQuery
        val answer = forward(query) ?: return
        queriesHandled += 1

        val reply = buildReply(sourceIp, destIp, sourcePort, destPort, answer)
        try { output?.write(reply) } catch (_: Throwable) {}
    }

    private fun forward(query: ByteArray): ByteArray? {
        return try {
            DatagramSocket().use { socket ->
                socket.soTimeout = 4_000
                val upstream = InetAddress.getByName("1.1.1.1")
                socket.send(DatagramPacket(query, query.size, upstream, 53))
                val buffer = ByteArray(4_096)
                val response = DatagramPacket(buffer, buffer.size)
                socket.receive(response)
                buffer.copyOf(response.length)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun buildReply(sourceIp: ByteArray, destIp: ByteArray, sourcePort: Int, destPort: Int, payload: ByteArray): ByteArray {
        val udpLength = 8 + payload.size
        val total = 20 + udpLength
        val packet = ByteArray(total)
        packet[0] = 0x45
        packet[2] = ((total shr 8) and 0xFF).toByte()
        packet[3] = (total and 0xFF).toByte()
        packet[4] = 0x00; packet[5] = 0x00
        packet[6] = 0x40; packet[7] = 0x00
        packet[8] = 64
        packet[9] = 17
        System.arraycopy(destIp, 0, packet, 12, 4)
        System.arraycopy(sourceIp, 0, packet, 16, 4)
        packet[20] = ((destPort shr 8) and 0xFF).toByte()
        packet[21] = (destPort and 0xFF).toByte()
        packet[22] = ((sourcePort shr 8) and 0xFF).toByte()
        packet[23] = (sourcePort and 0xFF).toByte()
        packet[24] = ((udpLength shr 8) and 0xFF).toByte()
        packet[25] = (udpLength and 0xFF).toByte()
        System.arraycopy(payload, 0, packet, 28, payload.size)
        val checksum = ipChecksum(packet, 20)
        packet[10] = ((checksum shr 8) and 0xFF).toByte()
        packet[11] = (checksum and 0xFF).toByte()
        return packet
    }

    private fun ipChecksum(packet: ByteArray, headerLength: Int): Int {
        var sum = 0
        var index = 0
        while (index + 1 < headerLength) {
            sum += ((packet[index].toInt() and 0xFF) shl 8) or (packet[index + 1].toInt() and 0xFF)
            index += 2
        }
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    /** Best-effort QNAME for the UI; the bytes are never altered. */
    private fun dnsQuestionName(query: ByteArray): String? {
        if (query.size < 13) return null
        var index = 12
        val labels = mutableListOf<String>()
        while (index < query.size) {
            val length = query[index].toInt() and 0xFF
            if (length == 0) break
            if (length > 63 || index + 1 + length > query.size) return null
            labels.add(String(query, index + 1, length))
            index += 1 + length
        }
        return if (labels.isEmpty()) null else labels.joinToString(".")
    }

    private fun notifyForeground(fullTunnel: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Leapin VPN", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val stop = PendingIntent.getService(
            this, 1, Intent(this, LeapinVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification: Notification = Notification.Builder(this, CHANNEL)
            .setContentTitle(if (fullTunnel) "Leapin 正在接管全部流量" else "Leapin 正在接管 DNS")
            .setContentText(if (fullTunnel) "TCP 经本机引擎，非 53 的 UDP 暂不透传" else "仅 53 端口；TCP 直通不受影响")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止", stop).build())
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun stopTunnel() {
        running = false
        isRunning = false
        isFullTunnel = false
        thread?.interrupt()
        thread = null
        udpRelay?.stop()
        udpRelay = null
        relay = null
        try { output?.close() } catch (_: Throwable) {}
        output = null
        try { tun?.close() } catch (_: Throwable) {}
        tun = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }
}
