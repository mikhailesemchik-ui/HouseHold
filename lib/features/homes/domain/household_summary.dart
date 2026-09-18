import 'package:flutter/foundation.dart';

@immutable
class HouseholdSummary {
  const HouseholdSummary({
    required this.incompleteTaskCount,
    required this.incompleteShoppingCount,
    required this.expenseCount,
    required this.activeMemberCount,
  });

  final int incompleteTaskCount;
  final int incompleteShoppingCount;
  final int expenseCount;
  final int activeMemberCount;
}
