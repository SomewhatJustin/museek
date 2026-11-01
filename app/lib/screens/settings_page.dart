import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider).session;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: session == null
          ? const Center(child: Text('This device is not paired.'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: const Text('Server'),
                    subtitle: Text(session.serverUrl),
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: () async {
                    final shouldSignOut = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Sign out?'),
                        content: const Text(
                          'You will need a new invitation code to pair this device again.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Sign out'),
                          ),
                        ],
                      ),
                    );
                    if (shouldSignOut != true || !context.mounted) {
                      return;
                    }
                    await ref.read(audioPlayerProvider).stop();
                    await ref
                        .read(sessionControllerProvider.notifier)
                        .signOut();
                    if (context.mounted) {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  },
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Sign out'),
                ),
              ],
            ),
    );
  }
}
