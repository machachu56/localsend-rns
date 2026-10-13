import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

/// Shows the device's RNS destination hash as a QR code for pairing.
class ShowQrPage extends StatelessWidget {
  final String destinationHash;
  final String alias;

  const ShowQrPage({
    required this.destinationHash,
    required this.alias,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final qrData = 'rns://$destinationHash?alias=${Uri.encodeComponent(alias)}';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Show QR Code'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              alias,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            PrettyQr(
              data: qrData,
              size: 250,
              errorCorrectLevel: QrErrorCorrectLevel.M,
            ),
            const SizedBox(height: 24),
            SelectableText(
              destinationHash,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Scan this QR code with another LocalSend-Reticulum device to pair.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Scans a QR code to discover another device's RNS destination hash.
class ScanQrPage extends StatelessWidget {
  const ScanQrPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.qr_code_scanner, size: 100, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 24),
            const Text(
              'Point your camera at a QR code from another device.',
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera scanner requires a barcode scanning plugin.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
