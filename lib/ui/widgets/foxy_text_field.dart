import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A 48 px field with its caption above it. Styling comes from the theme's
/// [InputDecorationTheme].
class FoxyTextField extends StatelessWidget {
  const FoxyTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.obscure = false,
    this.suffix,
    this.prefix,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
    this.textAlign = TextAlign.start,
    this.style,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final bool obscure;
  final Widget? suffix;
  final Widget? prefix;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final TextAlign textAlign;
  final TextStyle? style;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    // Pad vertically so the field is exactly 48 px whatever the text size.
    final textStyle = style ?? FoxyText.body;
    final lineHeight = MediaQuery.textScalerOf(context).scale(textStyle.fontSize ?? 14) * (textStyle.height ?? 1.4);
    final pad = ((48 - lineHeight) / 2).clamp(0.0, 24.0);
    final field = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        readOnly: readOnly,
        autofocus: autofocus,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: !obscure,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autofillHints: autofillHints,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        inputFormatters: inputFormatters,
        textAlign: textAlign,
        textAlignVertical: TextAlignVertical.center,
        cursorColor: FoxyColors.text,
        cursorWidth: 1.5,
        style: textStyle,
        mouseCursor: enabled ? SystemMouseCursors.text : SystemMouseCursors.basic,
        decoration: InputDecoration(
          hintText: hint,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: pad),
          suffixIcon: suffix,
          suffixIconConstraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          prefixIcon: prefix,
          prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 48),
        ),
      ),
    );
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(label!, style: FoxyText.caption),
        ),
        field,
      ],
    );
  }
}
