import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_log.dart';
import '../theme.dart';
import '../widgets/app_button.dart';
import '../widgets/foxy_icon.dart';
import '../widgets/page_header.dart';

/// The diagnostic log as plain scrollable text (Android's "Open log": there is
/// no Notepad to hand it to). Starts at the newest line; Copy puts all of it on
/// the clipboard so it can be pasted into a bug report.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key, this.loader});

  /// Replaced in tests.
  final Future<String> Function()? loader;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _scroll = ScrollController();
  String? _text;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final text = await (widget.loader ?? AppLog.readTail)();
    if (!mounted) return;
    setState(() => _text = text);
    // Newest at the bottom: start there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _copy() async {
    final text = _text ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return Scaffold(
      backgroundColor: FoxyColors.bg,
      body: PageScaffold(
        child: Column(
          children: [
            PageHeader(
              title: 'Log',
              actions: [
                HeaderButton(
                  icon: FoxyIcons.refresh,
                  tooltip: 'Refresh',
                  onTap: () => unawaited(_load()),
                ),
                AppButton(
                  label: _copied ? 'Copied' : 'Copy',
                  kind: AppButtonKind.text,
                  onPressed: text == null || text.isEmpty ? null : () => unawaited(_copy()),
                ),
              ],
            ),
            Expanded(
              child: text == null
                  ? const SizedBox.shrink()
                  : text.isEmpty
                  ? Center(
                      child: Text('The log is empty.', style: FoxyText.body.copyWith(color: FoxyColors.textDim)),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(FoxySpace.screen, 4, FoxySpace.screen, 16),
                        child: SelectableText(
                          text,
                          style: FoxyText.caption.copyWith(
                            fontFamily: 'monospace',
                            fontFamilyFallback: const ['Courier New', 'Consolas'],
                            fontSize: 11.5,
                            height: 1.45,
                            letterSpacing: 0,
                            color: FoxyColors.text,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
