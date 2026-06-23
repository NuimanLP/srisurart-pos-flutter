// SearchField — a rounded search input with a leading magnifier and a clear (✕)
// button that appears when there is text. Mirrors the preview search bar.
//
//   SearchField(
//     hint: 'ค้นหาอะไหล่…',
//     onChanged: (q) => setState(() => _query = q),
//   )
//
// Pass a [controller] to read/clear the value externally; otherwise it manages
// its own controller and shows/hides the clear button automatically.

import 'package:flutter/material.dart';

class SearchField extends StatefulWidget {
  final String hint;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;
  final bool autofocus;

  const SearchField({
    super.key,
    this.hint = 'ค้นหา…',
    this.onChanged,
    this.controller,
    this.autofocus = false,
  });

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final TextEditingController _controller;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _ownsController = widget.controller == null;
    _controller.addListener(_onChange);
  }

  void _onChange() {
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _controller.text.isNotEmpty;
    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        suffixIcon: hasText
            ? IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _controller.clear();
                  widget.onChanged?.call('');
                },
              )
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
