import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

class PairPage extends ConsumerStatefulWidget {
  const PairPage({super.key});

  @override
  ConsumerState<PairPage> createState() => _PairPageState();
}

class _PairPageState extends ConsumerState<PairPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _serverController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) {
      return;
    }
    await ref
        .read(sessionControllerProvider.notifier)
        .pair(
          serverUrl: _serverController.text,
          code: _codeController.text,
          deviceName: 'iPhone',
        );
  }

  @override
  Widget build(BuildContext context) {
    final sessionState = ref.watch(sessionControllerProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: CircleAvatar(
                        radius: 34,
                        child: Icon(Icons.headphones_rounded, size: 36),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Your music is waiting',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Enter the server address and invitation code you received. You only need to do this once.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _serverController,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.url],
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: 'https://music.example.com',
                        prefixIcon: Icon(Icons.cloud_outlined),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter the server address.'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _codeController,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      onFieldSubmitted: (_) => _pair(),
                      decoration: const InputDecoration(
                        labelText: 'Invitation code',
                        hintText: 'ABCD-2345',
                        prefixIcon: Icon(Icons.key_rounded),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter your invitation code.'
                          : null,
                    ),
                    if (sessionState.error != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          sessionState.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: sessionState.pairing ? null : _pair,
                      icon: sessionState.pairing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                      label: Text(
                        sessionState.pairing ? 'Connecting…' : 'Continue',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
