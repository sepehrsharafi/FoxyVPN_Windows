// Saves the sign-in tokens encrypted, so only this user can read them:
//  * Windows: DPAPI, so only this Windows user account can read the file.
//  * Android: AES-GCM with a key in the Android Keystore (see
//    android/.../SecureStore.kt), through the platform channel.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'fxa.dart';
import 'platform/android_platform.dart';
import 'platform/host.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
    Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptDart = int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
    Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _UnprotectNative = Int32 Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _UnprotectDart = int Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);

const _cryptprotectUiForbidden = 0x1;

final _crypt32 = DynamicLibrary.open('crypt32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
final _unprotect = _crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');
final _localFree =
    _kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
        'LocalFree');

Uint8List dpapiProtect(List<int> data) => _run(data, protect: true);
Uint8List dpapiUnprotect(List<int> data) => _run(data, protect: false);

Uint8List _run(List<int> data, {required bool protect}) {
  return using((arena) {
    final input = arena<_DataBlob>();
    final output = arena<_DataBlob>();
    final buffer = arena<Uint8>(data.isEmpty ? 1 : data.length);
    buffer.asTypedList(data.length).setAll(0, data);
    input.ref
      ..cbData = data.length
      ..pbData = buffer;
    final ok = protect
        ? _protect(input, nullptr, nullptr, nullptr, nullptr, _cryptprotectUiForbidden, output)
        : _unprotect(input, nullptr, nullptr, nullptr, nullptr, _cryptprotectUiForbidden, output);
    if (ok == 0) throw const OSError('Windows could not encrypt or decrypt the saved sign-in');
    try {
      return Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      _localFree(output.ref.pbData.cast());
    }
  });
}

class TokenStore {
  /// Windows: a DPAPI-encrypted file ([file], or %APPDATA%\FoxyVPN\auth.bin).
  /// Android (no [file]): the Android Keystore store behind the platform
  /// channel; its values are loaded into memory at startup (see
  /// lib/platform/android_platform.dart), so this stays synchronous.
  TokenStore([File? file]) : _file = file ?? (Host.isAndroid ? null : _defaultFile());

  final File? _file;

  static const _androidKey = 'auth';

  static File _defaultFile() {
    final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return File('$appData\\FoxyVPN\\auth.bin');
  }

  AuthTokens? load() {
    final file = _file;
    try {
      final String json;
      if (file == null) {
        final saved = AndroidPlatform.secureGet(_androidKey);
        if (saved == null) return null;
        json = saved;
      } else {
        if (!file.existsSync()) return null;
        json = utf8.decode(dpapiUnprotect(file.readAsBytesSync()));
      }
      return AuthTokens.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt or from another Windows user: behave as signed out.
      return null;
    }
  }

  void save(AuthTokens tokens) {
    final file = _file;
    if (file == null) {
      AndroidPlatform.securePut(_androidKey, jsonEncode(tokens.toJson()));
      return;
    }
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsBytesSync(dpapiProtect(utf8.encode(jsonEncode(tokens.toJson()))), flush: true);
    tmp.renameSync(file.path);
  }

  void clear() {
    final file = _file;
    if (file == null) {
      AndroidPlatform.secureDelete(_androidKey);
      return;
    }
    if (file.existsSync()) file.deleteSync();
  }
}
