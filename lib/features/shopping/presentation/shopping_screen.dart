import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_shadows.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_completion_checkbox.dart';
import 'package:household_os/core/widgets/app_completion_title.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_section_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/core/widgets/app_state_switcher.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/shopping/data/shopping_repository.dart';
import 'package:household_os/features/shopping/domain/shopping_item.dart';
import 'package:household_os/features/shopping/presentation/shopping_provider.dart';

// Composer capsule height (~48) + its resting gap above the nav/keyboard.
const _kComposerClearance = 68.0;

class ShoppingScreen extends ConsumerStatefulWidget {
  const ShoppingScreen({super.key, required this.householdId});

  final String householdId;

  @override
  ConsumerState<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends ConsumerState<ShoppingScreen> {
  final _addController = TextEditingController();
  final _addFocusNode = FocusNode();
  bool _isAdding = false;
  bool _composerFocused = false;

  ShoppingRepository get _repo => ShoppingRepository(supabaseClient);

  @override
  void initState() {
    super.initState();
    _addFocusNode.addListener(() {
      setState(() => _composerFocused = _addFocusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _addController.dispose();
    _addFocusNode.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final name = _addController.text;
    if (name.trim().isEmpty || _isAdding) return;
    setState(() => _isAdding = true);
    try {
      await _repo.addItem(householdId: widget.householdId, name: name);
      _addController.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to add item.')));
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<void> _clearCompleted() async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Clear completed items?',
      message: 'All completed items will be removed. This cannot be undone.',
      confirmLabel: 'Clear',
    );
    if (!confirmed || !mounted) return;
    try {
      await _repo.clearCompleted(widget.householdId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to clear completed items.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(shoppingItemsProvider(widget.householdId));

    // The shell's outer Scaffold already resizes for the keyboard, which
    // strips MediaQuery.viewInsets.bottom to 0 for everything nested inside
    // it (including this screen) — so that inset can't be read here to
    // detect "keyboard open". The composer's own focus state is the signal
    // that actually matters, and it anchors correctly to this already-
    // shrunk viewport without re-deriving any keyboard height.
    // The composer is a Positioned overlay, so it never consumes MediaQuery
    // padding itself. At rest it clears the nav bar; while focused the shell
    // has already resized this viewport above the keyboard (and hidden the
    // nav), so a small gap is all that is left to apply.
    final composerBottom = _composerFocused
        ? AppSpacing.sm
        : context.shellBottomInset + AppSpacing.sm;

    // The header is ordinary scrollable content now (not a pinned
    // `AppBar`) — every branch below places it as the first item of its
    // own scrollable, so it scrolls away with the page and returns
    // naturally at the top. The floating composer below is unaffected —
    // only the top header changes.
    const header = AppScreenHeader(
      leading: Center(child: AppBackButton()),
      title: 'Shopping',
    );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            // Keyed by state *category*, not by the list itself — a
            // realtime add/remove that keeps the list non-empty stays on
            // the 'data' key and never re-triggers the transition.
            child: AppStateSwitcher(
              stateKey: itemsAsync.when(
                loading: () => 'loading',
                error: (_, _) => 'error',
                data: (items) => items.isEmpty ? 'empty' : 'data',
              ),
              child: SafeArea(
                bottom: false,
                child: itemsAsync.when(
                  loading: () => ListView(
                    children: const [
                      header,
                      AppSkeletonList(
                        sectionCounts: {'': 5},
                        scrollable: false,
                      ),
                    ],
                  ),
                  error: (_, _) => ListView(
                    children: [
                      header,
                      AppErrorState(
                        message:
                            'Could not load shopping list. Please try again.',
                        onRetry: () => ref.invalidate(
                          shoppingItemsProvider(widget.householdId),
                        ),
                      ),
                    ],
                  ),
                  data: (items) {
                    if (items.isEmpty) {
                      return ListView(
                        children: const [
                          header,
                          AppEmptyState(
                            title: 'Nothing on the list.',
                            subtitle: 'Add the first item below.',
                          ),
                        ],
                      );
                    }
                    final active = items.where((i) => !i.isCompleted).toList();
                    final completed = items
                        .where((i) => i.isCompleted)
                        .toList();
                    return ListView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.only(
                        bottom: composerBottom + _kComposerClearance,
                      ),
                      children: [
                        header,
                        for (final item in active)
                          _ShoppingRow(
                            item: item,
                            onToggle: () => _toggle(context, item),
                            onEdit: () => _edit(context, item),
                            onDelete: () => _delete(context, item),
                          ),
                        if (completed.isNotEmpty) ...[
                          _CompletedHeader(
                            count: completed.length,
                            onClear: _clearCompleted,
                          ),
                          for (final item in completed)
                            _ShoppingRow(
                              item: item,
                              onToggle: () => _toggle(context, item),
                              onEdit: () => _edit(context, item),
                              onDelete: () => _delete(context, item),
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            left: AppSpacing.base,
            right: AppSpacing.base,
            bottom: composerBottom,
            child: _QuickAddComposer(
              controller: _addController,
              focusNode: _addFocusNode,
              isSubmitting: _isAdding,
              focused: _composerFocused,
              onSubmit: _addItem,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggle(BuildContext context, ShoppingItem item) async {
    try {
      final repo = ShoppingRepository(supabaseClient);
      if (item.isCompleted) {
        await repo.reopenItem(item.id);
      } else {
        await repo.completeItem(item.id);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to update item.')));
      }
    }
  }

  Future<void> _delete(BuildContext context, ShoppingItem item) async {
    try {
      await ShoppingRepository(supabaseClient).deleteItem(item.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to delete item.')));
      }
    }
  }

  void _edit(BuildContext context, ShoppingItem item) {
    showDialog<void>(
      context: context,
      builder: (_) => _ShoppingItemDialog(item: item),
    );
  }
}

// ---------------------------------------------------------------------------
// Completed section header
// ---------------------------------------------------------------------------

class _CompletedHeader extends StatelessWidget {
  const _CompletedHeader({required this.count, required this.onClear});

  final int count;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return AppSectionHeader(
      label: 'Completed · $count',
      trailing: TextButton(
        onPressed: onClear,
        child: const Text('Clear completed'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Active / completed row — an individual soft card (`docs/new_design`),
// matching the Today/Homes/Dashboard row family.
// ---------------------------------------------------------------------------

class _ShoppingRow extends StatelessWidget {
  const _ShoppingRow({
    required this.item,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final ShoppingItem item;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final completed = item.isCompleted;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.base,
        0,
        AppSpacing.base,
        AppSpacing.sm,
      ),
      child: AppSoftCard(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          children: [
            // No card-level onTap: the row itself isn't a destination, only
            // the checkbox and the menu are interactive.
            AppCompletionCheckbox(
              checked: completed,
              semanticLabel:
                  'Mark "${item.name}" as ${completed ? 'not done' : 'done'}',
              onChanged: onToggle,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppCompletionTitle(
                    text: item.name,
                    completed: completed,
                    baseStyle: textTheme.bodyMedium,
                    completedColor: colorScheme.onSurfaceVariant,
                  ),
                  if (item.quantity != null)
                    Text(
                      item.quantity!,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Item actions',
              icon: Icon(
                Icons.more_vert_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
              onSelected: (value) {
                if (value == 'edit') onEdit();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Level B quick-add composer — the signature Shopping interaction. The only
// other bounded BackdropFilter in the app besides the shell's glass nav bar,
// per the approved v2 composition (see docs/design/household_os_ui_handoff_v2.md).
// ---------------------------------------------------------------------------

class _QuickAddComposer extends StatelessWidget {
  const _QuickAddComposer({
    required this.controller,
    required this.focusNode,
    required this.isSubmitting,
    required this.focused,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSubmitting;
  final bool focused;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    // Phase 7B: same approved Telegram-style frosted-glass recipe as the
    // bottom nav (Phase 7A) — outer soft shadow, a 1lp bright rim on the
    // clip shape itself, bounded blur, warm translucent fill, then the same
    // restrained topLeft→bottomRight inner-highlight gradient underneath
    // the content. Shape/geometry (true pill, padding, field, button) is
    // unchanged; only the material layering changed.
    final shape = StadiumBorder(
      side: BorderSide(color: tokens.glassHighlight, width: 1),
    );

    // Motion Pass: focus lifts the shadow only — no blur/fill/rim/highlight
    // change, and no translation (that's owned by the AnimatedPositioned
    // above, which already handles the keyboard-clearance move).
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: ShapeDecoration(
        shape: shape,
        shadows: focused ? AppShadows.cardFocused : AppShadows.card,
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(color: tokens.glassFill),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      stops: const [0.0, 0.45],
                      colors: [
                        Colors.white.withValues(alpha: 0.55),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 3,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => onSubmit(),
                        enabled: !isSubmitting,
                        // Starts from the shared borderless base (every
                        // border state already none) and adds back only a
                        // restrained focus indicator — the composer sits on
                        // its own glass surface and must never show the
                        // app-wide outline.
                        decoration: kBorderlessInputDecoration.copyWith(
                          hintText: 'Add an item',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 13,
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: colorScheme.primary,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Semantics(
                      button: true,
                      label: 'Add item',
                      child: DecoratedBox(
                        decoration: const ShapeDecoration(
                          shape: CircleBorder(),
                          shadows: AppShadows.primaryCta,
                        ),
                        child: Material(
                          color: colorScheme.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: isSubmitting ? null : onSubmit,
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Center(
                                child: isSubmitting
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: colorScheme.onPrimary,
                                        ),
                                      )
                                    : Icon(
                                        Icons.add_rounded,
                                        color: colorScheme.onPrimary,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit dialog — unchanged: 2 fields, short, appropriate as a dialog.
// ---------------------------------------------------------------------------

// Edit-only: the quick-add composer is the sole creation path (Level B),
// so this dialog is never opened without an existing item. It previously
// accepted a nullable `existingItem` with an unreachable "create" branch
// that silently popped without writing anything if ever hit.
class _ShoppingItemDialog extends StatefulWidget {
  const _ShoppingItemDialog({required this.item});

  final ShoppingItem item;

  @override
  State<_ShoppingItemDialog> createState() => _ShoppingItemDialogState();
}

class _ShoppingItemDialogState extends State<_ShoppingItemDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _quantityController;
  String? _nameError;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.name);
    _quantityController = TextEditingController(
      text: widget.item.quantity ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text;
    final nameError = ShoppingRepository.validateName(name);
    if (nameError != null) {
      setState(() => _nameError = nameError);
      return;
    }
    if (_isSubmitting) return;
    setState(() {
      _nameError = null;
      _isSubmitting = true;
    });
    try {
      final repo = ShoppingRepository(supabaseClient);
      final quantity = _quantityController.text.trim().isEmpty
          ? null
          : _quantityController.text.trim();
      await repo.updateItem(
        itemId: widget.item.id,
        name: name,
        quantity: quantity,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to save item.')));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit item'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _nameError,
            ),
            autofocus: true,
            textInputAction: TextInputAction.next,
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _quantityController,
            decoration: const InputDecoration(
              labelText: 'Quantity (optional)',
              hintText: '2 kg, 1 pack...',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
