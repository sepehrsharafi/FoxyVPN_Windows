import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Interaction state handed to [Pressable.builder].
class PressState {
  const PressState({required this.enabled, this.hovered = false, this.pressed = false, this.focused = false});

  final bool enabled;
  final bool hovered;
  final bool pressed;

  /// Keyboard focus only (the ring is not shown after a mouse click).
  final bool focused;
}

/// The one clickable primitive in the app: pointer cursor, hover / pressed
/// state, keyboard focus (Tab) and Enter / Space activation. No ripples; the
/// [builder] decides how each state looks.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    required this.onTap,
    this.semanticLabel,
    this.focusable = true,
    this.autofocus = false,
    this.focusNode,
    this.tooltip,
    this.isButton = true,
  });

  final Widget Function(BuildContext context, PressState state) builder;

  /// Null disables the control.
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool focusable;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? tooltip;
  final bool isButton;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;
  FocusNode? _noFocus;

  bool get _enabled => widget.onTap != null;

  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  @override
  void didUpdateWidget(Pressable old) {
    super.didUpdateWidget(old);
    // Keyboard focus is kept when a control turns disabled: it stays where it is, inert.
    if (!_enabled && (_hovered || _pressed)) {
      _hovered = _pressed = false;
    }
  }

  @override
  void dispose() {
    _noFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = FocusableActionDetector(
      // Always enabled so a disabled control keeps keyboard focus (it just does nothing).
      enabled: true,
      autofocus: widget.autofocus && widget.focusable,
      focusNode: widget.focusable
          ? widget.focusNode
          : (_noFocus ??= FocusNode(canRequestFocus: false, skipTraversal: true)),
      shortcuts: _shortcuts,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      // Hover is tracked here rather than via onShowHoverHighlight, which only
      // reports while the focus highlight mode is 'traditional'.
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTap: widget.onTap,
          child: widget.builder(
            context,
            PressState(
              enabled: _enabled,
              hovered: _hovered && _enabled,
              pressed: _pressed && _enabled,
              focused: _focused,
            ),
          ),
        ),
      ),
    );
    child = Semantics(
      button: widget.isButton,
      enabled: _enabled,
      label: widget.semanticLabel,
      // With an explicit label the inner texts (letters, ms) would only repeat it.
      excludeSemantics: widget.semanticLabel != null,
      child: child,
    );
    if (widget.tooltip != null) {
      // The label is already in the semantics; don't announce it twice.
      child = Tooltip(message: widget.tooltip, excludeFromSemantics: true, child: child);
    }
    return child;
  }
}

/// Decoration helper: a rounded box that changes fill on hover / press and
/// draws a keyboard focus ring.
class PressableBox extends StatelessWidget {
  const PressableBox({
    super.key,
    required this.state,
    required this.child,
    this.radius = FoxySpace.controlRadius,
    this.base = Colors.transparent,
    this.hover = FoxyColors.surfaceHi,
    this.pressed = FoxyColors.surfaceHi,
    this.border,
    this.padding,
    this.width,
    this.height,
    this.minHeight,
    this.alignment,
  });

  final PressState state;
  final Widget child;
  final double radius;
  final Color base;
  final Color hover;
  final Color pressed;
  final Color? border;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  /// Use instead of [height] where the content can grow with the text scale.
  final double? minHeight;
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final fill = state.pressed ? pressed : (state.hovered ? hover : base);
    return AnimatedContainer(
      duration: FoxySpace.fast,
      curve: Curves.easeOut,
      width: width,
      height: height,
      constraints: minHeight == null ? null : BoxConstraints(minHeight: minHeight!),
      padding: padding,
      alignment: alignment,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? Colors.transparent),
      ),
      // The focus ring is painted over the content so it never shifts layout.
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: state.focused ? FoxyColors.focus : Colors.transparent, width: 1.5),
      ),
      child: child,
    );
  }
}
