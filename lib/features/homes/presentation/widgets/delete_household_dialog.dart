import 'package:flutter/material.dart';

/// Asks the owner to type the household name before it is deleted for good.
///
/// [onDelete] runs while the dialog stays open, so the confirm button is
/// disabled during the request (no double submissions) and a failure keeps the
/// dialog open with a message. Returns true only after [onDelete] succeeded.
Future<bool> showDeleteHouseholdDialog(
  BuildContext context, {
  required String householdName,
  required Future<void> Function() onDelete,
  required String Function(Object error) errorMessage,
}) async {
  final deleted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DeleteHouseholdDialog(
      householdName: householdName,
      onDelete: onDelete,
      errorMessage: errorMessage,
    ),
  );
  return deleted ?? false;
}

class _DeleteHouseholdDialog extends StatefulWidget {
  const _DeleteHouseholdDialog({
    required this.householdName,
    required this.onDelete,
    required this.errorMessage,
  });

  final String householdName;
  final Future<void> Function() onDelete;
  final String Function(Object error) errorMessage;

  @override
  State<_DeleteHouseholdDialog> createState() => _DeleteHouseholdDialogState();
}

class _DeleteHouseholdDialogState extends State<_DeleteHouseholdDialog> {
  final _nameController = TextEditingController();
  bool _isDeleting = false;
  String? _error;

  bool get _nameMatches => _nameController.text == widget.householdName;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_isDeleting || !_nameMatches) return;
    setState(() {
      _isDeleting = true;
      _error = null;
    });
    try {
      await widget.onDelete();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDeleting = false;
        _error = widget.errorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Delete home?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'All tasks, shopping lists, expenses, payments and financial '
              'history of this home will be permanently deleted for everyone. '
              'This cannot be undone.',
            ),
            const SizedBox(height: 12),
            Text('Type "${widget.householdName}" to confirm.'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              enabled: !_isDeleting,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Home name'),
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isDeleting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _nameMatches && !_isDeleting ? _delete : null,
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          child: _isDeleting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Delete'),
        ),
      ],
    );
  }
}
