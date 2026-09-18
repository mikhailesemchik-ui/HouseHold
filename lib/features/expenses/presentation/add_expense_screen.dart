import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_money_text.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/money.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/widgets/member_option.dart';

/// Full-screen expense create form — the old `AddExpenseDialog` `AlertDialog`
/// could not host an amount hero, a participant picker, and the keyboard at
/// once. Same World B architecture as the Task Form: root navigator,
/// `fullscreenDialog: true`, its own `Scaffold` owning keyboard resize, no
/// manual `viewInsets` math.
class ExpenseFormScreen extends ConsumerStatefulWidget {
  const ExpenseFormScreen({super.key, required this.householdId});

  final String householdId;

  @override
  ConsumerState<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends ConsumerState<ExpenseFormScreen> {
  final _amountController = TextEditingController();
  final _titleController = TextEditingController();
  final _amountFocusNode = FocusNode();
  final _titleFocusNode = FocusNode();

  String? _amountError;
  String? _titleError;
  String? _participantsError;
  String? _selectedPayerId;
  Set<String> _selectedParticipantIds = {};
  bool _isSubmitting = false;
  bool _isDirty = false;

  // Guards `_initDefaultsOnce` so it runs exactly once, the first time member
  // data becomes available — never again on a later rebuild. The bug this
  // fixes: the previous dialog re-derived defaults from `build` on every
  // rebuild, so unchecking the last participant triggered a rebuild that
  // immediately re-checked everyone.
  bool _defaultsInitialized = false;

  @override
  void dispose() {
    _amountController.dispose();
    _titleController.dispose();
    _amountFocusNode.dispose();
    _titleFocusNode.dispose();
    super.dispose();
  }

  void _initDefaultsOnce(List<ExpenseMember> members, String currentUserId) {
    if (_defaultsInitialized || members.isEmpty) return;
    _defaultsInitialized = true;
    _selectedPayerId = currentUserId.isNotEmpty
        ? currentUserId
        : members.first.userId;
    _selectedParticipantIds = members.map((m) => m.userId).toSet();
  }

  void _onAmountChanged(String _) {
    setState(() {
      _isDirty = true;
      if (_amountError != null) _amountError = null;
    });
  }

  void _onTitleChanged(String _) {
    setState(() {
      _isDirty = true;
      if (_titleError != null) _titleError = null;
    });
  }

  void _selectPayer(String userId) {
    setState(() {
      _selectedPayerId = userId;
      _isDirty = true;
    });
  }

  void _toggleParticipant(String userId) {
    setState(() {
      _selectedParticipantIds = _selectedParticipantIds.contains(userId)
          ? ({..._selectedParticipantIds}..remove(userId))
          : {..._selectedParticipantIds, userId};
      _isDirty = true;
      _participantsError = null;
    });
  }

  Future<void> _submit() async {
    final titleError = ExpenseRepository.validateTitle(_titleController.text);
    final amountCents = Money.parseAmountCents(_amountController.text);
    final amountError = amountCents == null
        ? 'Enter a valid amount (e.g. 12.50)'
        : null;
    final participantsError = _selectedParticipantIds.isEmpty
        ? 'Select at least one participant.'
        : null;

    if (titleError != null ||
        amountError != null ||
        participantsError != null) {
      setState(() {
        _titleError = titleError;
        _amountError = amountError;
        _participantsError = participantsError;
      });
      return;
    }

    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    try {
      await ExpenseRepository(supabaseClient).createEqualSplitExpense(
        householdId: widget.householdId,
        title: _titleController.text,
        amountCents: amountCents!,
        currency: 'EUR',
        paidBy: _selectedPayerId!,
        participantIds: _selectedParticipantIds.toList(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // Amount, title, payer, and participants are left exactly as entered —
      // a network failure is a form-level, recoverable message, never a
      // reason to discard what the user typed.
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to add expense. Please try again.'),
          ),
        );
      }
    }
  }

  Future<void> _handlePopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    final discard = await confirmDestructive(
      context,
      title: 'Discard expense?',
      message: 'Your entered amount and details will be lost.',
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
        child: useCloseButton ? const AppCloseButton() : const AppBackButton(),
      ),
      title: 'New expense',
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
                    child: const Text('Add'),
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
              _initDefaultsOnce(members, currentUserId);
              return _ExpenseFormFields(
                header: header,
                amountController: _amountController,
                titleController: _titleController,
                amountFocusNode: _amountFocusNode,
                titleFocusNode: _titleFocusNode,
                amountError: _amountError,
                titleError: _titleError,
                participantsError: _participantsError,
                members: members,
                selectedPayerId: _selectedPayerId,
                selectedParticipantIds: _selectedParticipantIds,
                onAmountChanged: _onAmountChanged,
                onTitleChanged: _onTitleChanged,
                onSelectPayer: _selectPayer,
                onToggleParticipant: _toggleParticipant,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ExpenseFormFields extends StatelessWidget {
  const _ExpenseFormFields({
    required this.header,
    required this.amountController,
    required this.titleController,
    required this.amountFocusNode,
    required this.titleFocusNode,
    required this.amountError,
    required this.titleError,
    required this.participantsError,
    required this.members,
    required this.selectedPayerId,
    required this.selectedParticipantIds,
    required this.onAmountChanged,
    required this.onTitleChanged,
    required this.onSelectPayer,
    required this.onToggleParticipant,
  });

  final Widget header;
  final TextEditingController amountController;
  final TextEditingController titleController;
  final FocusNode amountFocusNode;
  final FocusNode titleFocusNode;
  final String? amountError;
  final String? titleError;
  final String? participantsError;
  final List<ExpenseMember> members;
  final String? selectedPayerId;
  final Set<String> selectedParticipantIds;
  final ValueChanged<String> onAmountChanged;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onSelectPayer;
  final ValueChanged<String> onToggleParticipant;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final selectedParticipants = members
        .where((m) => selectedParticipantIds.contains(m.userId))
        .toList();
    final amountCents = Money.parseAmountCents(amountController.text);

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
            AppSpacing.sm,
            AppSpacing.base,
            AppSpacing.xl,
          ),
          child: Column(
            children: [
              // Hero amount — borderless, tabular. Left-aligned (not centred) so
              // the € prefix and the digits always sit directly next to each
              // other, regardless of amount length — centring the digits inside
              // the remaining space (the previous approach) let a short amount
              // drift away from the prefix, which visually detached the two.
              // Bounded width rather than shrink-to-content so it never fights
              // TextField's own layout.
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: TextField(
                    controller: amountController,
                    focusNode: amountFocusNode,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => titleFocusNode.requestFocus(),
                    onChanged: onAmountChanged,
                    style: textTheme.heroNumber?.copyWith(fontSize: 48),
                    decoration: kBorderlessInputDecoration.copyWith(
                      hintText: '0.00',
                      prefixText: '€',
                      prefixStyle: textTheme.heroNumber?.copyWith(
                        fontSize: 28,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      errorText: amountError,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: titleController,
                focusNode: titleFocusNode,
                decoration: InputDecoration(
                  labelText: 'Title',
                  errorText: titleError,
                ),
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                onChanged: onTitleChanged,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Paid by',
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
                      selected: selectedPayerId == m.userId,
                      onTap: () => onSelectPayer(m.userId),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Split between',
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
                      selected: selectedParticipantIds.contains(m.userId),
                      onTap: () => onToggleParticipant(m.userId),
                    ),
                ],
              ),
              if (participantsError != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  participantsError!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ],
              if (amountCents != null && selectedParticipants.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                _ShareSummary(
                  amountCents: amountCents,
                  members: selectedParticipants,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Per-person share, using the existing equal-split calculation directly —
/// shown as a list rather than a single "€X each" line, since a remainder
/// means shares are not always identical to the cent.
class _ShareSummary extends StatelessWidget {
  const _ShareSummary({required this.amountCents, required this.members});

  final int amountCents;
  final List<ExpenseMember> members;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final shares = Money.equalSplitShares(amountCents, members.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Each person pays',
          style: textTheme.eyebrow?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        for (var i = 0; i < members.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    members[i].displayName,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppMoneyText(
                  Money.format(shares[i], 'EUR'),
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
