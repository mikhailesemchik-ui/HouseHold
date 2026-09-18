import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/money.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/widgets/member_option.dart';

/// Full-screen "record a repayment" form — replaces `_RecordSettlementDialog`
/// (an `AlertDialog`). Combines member selection, amount input, and an
/// optional note, which is exactly the field count the Phase-D brief says
/// does not belong in a dialog. Same World B architecture as the Task Form
/// and the expense form.
class SettlementFormScreen extends ConsumerStatefulWidget {
  const SettlementFormScreen({super.key, required this.householdId});

  final String householdId;

  @override
  ConsumerState<SettlementFormScreen> createState() =>
      _SettlementFormScreenState();
}

class _SettlementFormScreenState extends ConsumerState<SettlementFormScreen> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  final _amountFocusNode = FocusNode();

  String? _fromUserId;
  String? _toUserId;
  String? _amountError;
  String? _membersError;
  bool _isSubmitting = false;
  bool _isDirty = false;
  bool _defaultsInitialized = false;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  void _initDefaultsOnce(List<ExpenseMember> members, String currentUserId) {
    if (_defaultsInitialized || members.isEmpty) return;
    _defaultsInitialized = true;
    _fromUserId = currentUserId.isNotEmpty
        ? currentUserId
        : members.first.userId;
    _toUserId = members
        .firstWhere((m) => m.userId != _fromUserId, orElse: () => members.first)
        .userId;
  }

  void _selectFrom(String userId) {
    setState(() {
      _fromUserId = userId;
      _isDirty = true;
      _membersError = null;
    });
  }

  void _selectTo(String userId) {
    setState(() {
      _toUserId = userId;
      _isDirty = true;
      _membersError = null;
    });
  }

  void _onAmountChanged(String _) {
    setState(() {
      _isDirty = true;
      if (_amountError != null) _amountError = null;
    });
  }

  void _onNoteChanged(String _) {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  Future<void> _submit() async {
    final fromId = _fromUserId;
    final toId = _toUserId;

    final membersError = (fromId == null || toId == null || fromId == toId)
        ? 'Select two different members.'
        : null;
    final amountCents = Money.parseAmountCents(_amountController.text);
    final amountError = amountCents == null
        ? 'Enter a valid amount (e.g. 12.50)'
        : null;

    if (membersError != null || amountError != null) {
      setState(() {
        _membersError = membersError;
        _amountError = amountError;
      });
      return;
    }

    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    try {
      await ExpenseRepository(supabaseClient).createSettlement(
        householdId: widget.householdId,
        fromUserId: fromId!,
        toUserId: toId!,
        amountCents: amountCents!,
        currency: 'EUR',
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to record payment. Please try again.'),
          ),
        );
      }
    }
  }

  Future<void> _handlePopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    final discard = await confirmDestructive(
      context,
      title: 'Discard payment record?',
      message: 'Your entered details will be lost.',
      confirmLabel: 'Discard',
    );
    if (!mounted) return;
    if (!discard) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(expenseMembersProvider(widget.householdId));
    final currentUserId = ref.watch(currentUserIdProvider);
    final colorScheme = Theme.of(context).colorScheme;

    // The header is ordinary scrollable content now (not a pinned
    // `AppBar`) — every branch below places it as the first item of its
    // own scrollable, unpadded (matching the removed AppBar's own
    // edge-to-edge geometry), so it scrolls away with the rest of the form
    // and returns naturally at the top. `AppBar` itself picks `CloseButton`
    // vs `BackButton` from `ModalRoute.fullscreenDialog` — replicated here
    // so the leading icon stays exactly what it was for both the
    // `fullscreenDialog` production route and a plain-push test host.
    final useCloseButton = ModalRoute.of(context)?.fullscreenDialog ?? false;
    final header = AppScreenHeader(
      leading: Center(
        child: useCloseButton ? const CloseButton() : const BackButton(),
      ),
      title: 'Record settlement',
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.xs),
          child: Center(
            child: _isSubmitting
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    onPressed: _defaultsInitialized ? _submit : null,
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.primary,
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    child: const Text('Record'),
                  ),
          ),
        ),
      ],
    );

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: _handlePopInvoked,
      child: Scaffold(
        // Pushed on the root navigator, outside the shell's `AppBackground`
        // — see `appFlatBackgroundFallback`'s doc comment.
        backgroundColor: appFlatBackgroundFallback,
        body: SafeArea(
          child: membersAsync.when(
            loading: () => ListView(
              children: [
                header,
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            ),
            error: (_, _) => ListView(
              children: [
                header,
                AppErrorState(
                  message: 'Could not load members. Please try again.',
                  onRetry: () => ref.invalidate(
                    expenseMembersProvider(widget.householdId),
                  ),
                ),
              ],
            ),
            data: (members) {
              if (members.length < 2) {
                return ListView(
                  children: [
                    header,
                    const AppEmptyState(
                      title:
                          'At least two active members are needed to record a payment.',
                    ),
                  ],
                );
              }
              _initDefaultsOnce(members, currentUserId);
              return _SettlementFormFields(
                header: header,
                members: members,
                fromUserId: _fromUserId,
                toUserId: _toUserId,
                membersError: _membersError,
                amountController: _amountController,
                amountFocusNode: _amountFocusNode,
                amountError: _amountError,
                noteController: _noteController,
                onSelectFrom: _selectFrom,
                onSelectTo: _selectTo,
                onAmountChanged: _onAmountChanged,
                onNoteChanged: _onNoteChanged,
                onAmountSubmitted: _submit,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SettlementFormFields extends StatelessWidget {
  const _SettlementFormFields({
    required this.header,
    required this.members,
    required this.fromUserId,
    required this.toUserId,
    required this.membersError,
    required this.amountController,
    required this.amountFocusNode,
    required this.amountError,
    required this.noteController,
    required this.onSelectFrom,
    required this.onSelectTo,
    required this.onAmountChanged,
    required this.onNoteChanged,
    required this.onAmountSubmitted,
  });

  final Widget header;
  final List<ExpenseMember> members;
  final String? fromUserId;
  final String? toUserId;
  final String? membersError;
  final TextEditingController amountController;
  final FocusNode amountFocusNode;
  final String? amountError;
  final TextEditingController noteController;
  final ValueChanged<String> onSelectFrom;
  final ValueChanged<String> onSelectTo;
  final ValueChanged<String> onAmountChanged;
  final ValueChanged<String> onNoteChanged;
  final VoidCallback onAmountSubmitted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      // The header must stay unpadded — the form fields' horizontal/
      // bottom insets live on the inner `Padding` below instead of on
      // this outer list, which opts out of auto-consuming MediaQuery
      // itself so it can't double-count anything the inner Padding
      // already applies explicitly.
      padding: EdgeInsets.zero,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.base,
            AppSpacing.base,
            AppSpacing.base,
            AppSpacing.xl,
          ),
          child: Column(
            children: [
              Text(
                'From',
                style: textTheme.eyebrow?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final m in members)
                    MemberOption(
                      label: m.displayName,
                      selected: fromUserId == m.userId,
                      onTap: () => onSelectFrom(m.userId),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'To',
                style: textTheme.eyebrow?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final m in members)
                    MemberOption(
                      label: m.displayName,
                      selected: toUserId == m.userId,
                      onTap: () => onSelectTo(m.userId),
                    ),
                ],
              ),
              if (membersError != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  membersError!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: amountController,
                focusNode: amountFocusNode,
                decoration: InputDecoration(
                  labelText: 'Amount (EUR)',
                  hintText: '0.00',
                  prefixText: '€',
                  errorText: amountError,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                onChanged: onAmountChanged,
              ),
              const SizedBox(height: AppSpacing.base),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
                textInputAction: TextInputAction.done,
                onChanged: onNoteChanged,
                onSubmitted: (_) => onAmountSubmitted(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
