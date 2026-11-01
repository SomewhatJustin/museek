class PairingLink {
  const PairingLink({required this.serverUrl, required this.code});

  final String serverUrl;
  final String code;

  static final _codePattern = RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$');

  static PairingLink? tryParse(Uri uri) {
    if (uri.scheme.toLowerCase() != 'museek' ||
        uri.host.toLowerCase() != 'pair' ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }
    final serverValue = uri.queryParameters['server']?.trim() ?? '';
    final code = uri.queryParameters['code']?.trim().toUpperCase() ?? '';
    final server = Uri.tryParse(serverValue);
    if (server == null ||
        !server.hasAuthority ||
        (server.scheme != 'https' && server.scheme != 'http') ||
        server.userInfo.isNotEmpty ||
        !_codePattern.hasMatch(code)) {
      return null;
    }
    if (server.scheme == 'http' &&
        server.host != 'localhost' &&
        server.host != '127.0.0.1' &&
        server.host != '::1') {
      return null;
    }
    return PairingLink(serverUrl: server.toString(), code: code);
  }
}

bool isSameMuseekHost(String currentServerUrl, String invitedServerUrl) {
  final current = Uri.tryParse(currentServerUrl);
  final invited = Uri.tryParse(invitedServerUrl);
  return current != null &&
      invited != null &&
      current.hasAuthority &&
      invited.hasAuthority &&
      current.scheme == invited.scheme &&
      current.host == invited.host;
}
