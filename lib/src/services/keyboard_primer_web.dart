import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Opens the on-screen keyboard ahead of a text field that is about to
/// appear.
///
/// iOS Safari only shows the keyboard when focus happens during a tap, but an
/// autofocused field in a dialog is focused a frame later. Focusing a hidden
/// input during the tap opens the keyboard, and it stays open when the
/// field takes focus. Call this synchronously from the tap handler.
void primeKeyboard() {
  final input = web.HTMLInputElement()
    ..type = 'text'
    ..setAttribute('aria-hidden', 'true')
    ..tabIndex = -1;
  // 16px stops iOS zooming in on focus; the input itself is never seen.
  input.style
    ..position = 'fixed'
    ..top = '0'
    ..left = '0'
    ..width = '1px'
    ..height = '1px'
    ..opacity = '0'
    ..fontSize = '16px'
    ..pointerEvents = 'none';
  web.document.body?.append(input);
  input.focus();

  // Once the real field has focus this one is no longer needed.
  input.addEventListener('blur', ((web.Event _) => input.remove()).toJS);
  Future<void>.delayed(const Duration(seconds: 2), () => input.remove());
}
