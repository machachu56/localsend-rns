import 'dart:async';

import 'package:common/src/rns/rns_bridge.dart';
import 'package:common/src/rns/rns_interface_config.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

final _logger = Logger('RnsNetworkPage');

class RnsNetworkPage extends StatefulWidget {
  const RnsNetworkPage({super.key});

  @override
  State<RnsNetworkPage> createState() => _RnsNetworkPageState();
}

class _RnsNetworkPageState extends State<RnsNetworkPage> {
  List<RnsInterfaceConfig> _interfaces = [];
  bool _loading = true;
  String? _error;
  Timer? _timeout;
  StreamSubscription<RnsBridgeEvent>? _subscription;

  // The bridge normally answers within a second or two; beyond this we show an error instead of a spinner.
  static const _startupTimeout = Duration(seconds: 20);

  void _setError(String message) {
    _timeout?.cancel();
    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscription?.cancel();
    final bridge = context.ref.read(rnsBridgeProvider);
    _subscription = bridge.events.listen((event) {
      if (event.type == 'ready') {
        setState(() => _error = null);
        bridge.getInterfaces();
      } else if (event.type == 'interfaces_list') {
        _timeout?.cancel();
        final list = (event.data['interfaces'] as List<dynamic>?) ?? [];
        setState(() {
          _interfaces = list.map((e) => RnsInterfaceConfig.fromJson(e as Map<String, dynamic>)).toList();
          _loading = false;
        });
      } else if (event.type == 'interfaces_configured') {
        bridge.getInterfaces();
      } else if (event.type == 'bridge_exited') {
        _setError(bridge.lastError ?? 'The Reticulum bridge stopped.');
      } else if (event.type == 'bridge_error') {
        _logger.warning('Bridge error: ${event.data['message']}');
        _setError(event.data['message'] as String? ?? 'Unknown bridge error');
      }
    });

    // The bridge may have failed before this page was opened.
    final existingError = bridge.lastError;
    if (existingError != null) {
      _error = existingError;
      _loading = false;
      return;
    }
    // If bridge already running, request interfaces now
    if (bridge.isRunning) {
      bridge.getInterfaces();
    }
    _timeout?.cancel();
    if (_loading) {
      _timeout = Timer(_startupTimeout, () {
        if (_loading) _setError('The Reticulum bridge did not respond.');
      });
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  void _addInterface() {
    showDialog(
      context: context,
      builder: (ctx) => _InterfaceEditDialog(
        onSave: (config) {
          final newList = [..._interfaces, config];
          setState(() => _interfaces = newList);
          _saveInterfaces(newList);
        },
      ),
    );
  }

  void _editInterface(int index) {
    showDialog(
      context: context,
      builder: (ctx) => _InterfaceEditDialog(
        initial: _interfaces[index],
        onSave: (config) {
          final newList = [..._interfaces]..[index] = config;
          setState(() => _interfaces = newList);
          _saveInterfaces(newList);
        },
      ),
    );
  }

  void _deleteInterface(int index) {
    final newList = [..._interfaces]..removeAt(index);
    setState(() => _interfaces = newList);
    _saveInterfaces(newList);
  }

  void _toggleInterface(int index) {
    final iface = _interfaces[index];
    final newList = [..._interfaces]..[index] = iface.copyWith(enabled: !iface.enabled);
    setState(() => _interfaces = newList);
    _saveInterfaces(newList);
  }

  Future<void> _saveInterfaces(List<RnsInterfaceConfig> interfaces) async {
    final bridge = context.ref.read(rnsBridgeProvider);
    await bridge.configureInterfaces(interfaces.map((i) => i.toJson()).toList());
  }

  @override
  Widget build(BuildContext context) {
    final identityHash = context.watch(rnsIdentityHashProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reticulum Network'),
        actions: [
          if (!_loading && _error == null)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: _addInterface,
              tooltip: 'Add Interface',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (identityHash != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('RNS Identity', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    PrettyQr(
                      data: 'rns://$identityHash',
                      size: 200,
                      errorCorrectLevel: QrErrorCorrectLevel.M,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      identityHash,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ] else if (_error != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 12),
                    const Text('Reticulum is not available', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SelectableText(_error!, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ] else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    const Text('Connecting to RNS bridge...'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_error == null) ...[
            const _NetworkPasswordCard(),
            const SizedBox(height: 16),
          ],
          Text('Network Interfaces', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_error != null)
            const SizedBox.shrink()
          else if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else if (_interfaces.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.wifi_off, size: 48, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
                    const SizedBox(height: 12),
                    const Text('No interfaces configured'),
                    const SizedBox(height: 4),
                    Text(
                      'Add a TCPClientInterface to connect to other Reticulum peers',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else
            ..._interfaces.asMap().entries.map((entry) {
              final i = entry.key;
              final iface = entry.value;
              return Card(
                child: ListTile(
                  leading: Icon(
                    iface.enabled ? Icons.wifi : Icons.wifi_off,
                    color: iface.enabled ? null : Colors.grey,
                  ),
                  title: Text(iface.name),
                  subtitle: Text(
                    '${iface.type}${iface.targetHost != null ? ' @ ${iface.targetHost}:${iface.targetPort ?? "5421"}' : ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: iface.enabled,
                        onChanged: (_) => _toggleInterface(i),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          switch (value) {
                            case 'edit':
                              _editInterface(i);
                              break;
                            case 'delete':
                              _deleteInterface(i);
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('Edit')),
                          const PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 16),
          Text(
            'Interfaces are persisted to the RNS config file.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

/// Mbit/s text to bit/s; null when empty or invalid. RNS needs at least 5 bit/s.
int? _parseBitrate(String text) {
  final mbit = double.tryParse(text.trim().replaceAll(',', '.'));
  if (mbit == null || mbit <= 0) return null;
  return (mbit * 1000000).round();
}

class _InterfaceEditDialog extends StatefulWidget {
  final RnsInterfaceConfig? initial;
  final void Function(RnsInterfaceConfig config) onSave;

  const _InterfaceEditDialog({
    this.initial,
    required this.onSave,
  });

  @override
  State<_InterfaceEditDialog> createState() => _InterfaceEditDialogState();
}

class _InterfaceEditDialogState extends State<_InterfaceEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _bitrateController;
  late String _type;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial?.name ?? '');
    _hostController = TextEditingController(text: widget.initial?.targetHost ?? '');
    _portController = TextEditingController(text: widget.initial?.targetPort ?? '5421');
    final bitrate = widget.initial?.bitrate;
    _bitrateController = TextEditingController(text: bitrate == null ? '' : '${bitrate / 1000000}'.replaceFirst(RegExp(r'\.0$'), ''));
    _type = widget.initial?.type ?? 'TCPClientInterface';
    _enabled = widget.initial?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _bitrateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial != null ? 'Edit Interface' : 'Add Interface'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Interface Name', hintText: 'My Mesh Link'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Interface Type'),
              items: const [
                DropdownMenuItem(value: 'TCPClientInterface', child: Text('TCP Client')),
                DropdownMenuItem(value: 'TCPServerInterface', child: Text('TCP Server')),
                DropdownMenuItem(value: 'UDPInterface', child: Text('UDP')),
              ],
              onChanged: (v) => setState(() => _type = v!),
            ),
            const SizedBox(height: 12),
            if (_type == 'TCPClientInterface' || _type == 'UDPInterface') ...[
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(labelText: 'Target Host', hintText: '192.168.1.100'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _portController,
                decoration: const InputDecoration(labelText: 'Target Port', hintText: '5421'),
                keyboardType: TextInputType.number,
              ),
            ],
            if (_type == 'TCPServerInterface') ...[
              TextField(
                controller: _portController,
                decoration: const InputDecoration(labelText: 'Listen Port', hintText: '5421'),
                keyboardType: TextInputType.number,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _bitrateController,
              decoration: const InputDecoration(
                labelText: 'Bandwidth (Mbit/s, optional)',
                hintText: '100',
                helperText: 'Empty = RNS default. Higher values allow larger packets for file transfers.',
                helperMaxLines: 2,
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              title: const Text('Enabled'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v ?? true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_nameController.text.trim().isEmpty) return;
            widget.onSave(RnsInterfaceConfig(
              name: _nameController.text.trim(),
              type: _type,
              enabled: _enabled,
              targetHost: _hostController.text.trim().isEmpty ? null : _hostController.text.trim(),
              targetPort: _portController.text.trim().isEmpty ? null : _portController.text.trim(),
              bitrate: _parseBitrate(_bitrateController.text),
            ));
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}


/// Devices only see each other (and can only send files to each other) over Reticulum
/// when they use the same password. Empty = open network.
class _NetworkPasswordCard extends StatefulWidget {
  const _NetworkPasswordCard();

  @override
  State<_NetworkPasswordCard> createState() => _NetworkPasswordCardState();
}

class _NetworkPasswordCardState extends State<_NetworkPasswordCard> {
  late final TextEditingController _controller;
  late String _saved;
  bool _obscure = true;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _saved = context.ref.read(persistenceProvider).getRnsPassword();
    _controller = TextEditingController(text: _saved);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final password = _controller.text;
    await context.ref.read(persistenceProvider).setRnsPassword(password);
    if (!mounted) return;
    await context.ref.read(rnsBridgeProvider).setPassword(password);
    if (!mounted) return;
    setState(() => _saved = password);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(password.isEmpty ? 'Password removed: open network' : 'Password saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final changed = _controller.text != _saved;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Network password', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              _saved.isEmpty
                  ? 'Open network: any device can find you and send you files.'
                  : 'Only devices with the same password can find you or send you files.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: 'Leave empty for an open network. Must be identical on every device.',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: changed ? _save : null,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
