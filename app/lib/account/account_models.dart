const accountTermsVersion = '2026-10-23.google.v1';

class AccountFailure implements Exception {
  const AccountFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class AccountIdentity {
  const AccountIdentity({required this.uid, this.name, this.email});
  final String uid;
  final String? name;
  final String? email;
}

class EmergencyContact {
  const EmergencyContact({
    required this.name,
    required this.phone,
    this.relationship = '',
  });
  final String name;
  final String phone;
  final String relationship;

  factory EmergencyContact.validated(
    String name,
    String phone,
    String relationship,
  ) {
    final normalized = phone.replaceAll(RegExp(r'[\s()\-]'), '');
    final international = normalized.startsWith('+')
        ? normalized
        : '+852$normalized';
    if (name.trim().isEmpty || name.trim().length > 60) {
      throw const AccountFailure('invalid-contact', '請填寫一至六十字的聯絡人稱呼。');
    }
    if (!RegExp(r'^\+[1-9][0-9]{6,14}$').hasMatch(international) ||
        (international.startsWith('+852') && international.length != 12)) {
      throw const AccountFailure(
        'invalid-phone',
        '請填寫有效電話；香港號碼為八位數，其他地區請加國際區號。',
      );
    }
    if (relationship.trim().length > 30) {
      throw const AccountFailure('invalid-contact', '關係最多三十字，亦可留空。');
    }
    return EmergencyContact(
      name: name.trim(),
      phone: international,
      relationship: relationship.trim(),
    );
  }

  Map<String, Object> toJson() => {
    'name': name,
    'phone': phone,
    'relationship': relationship,
  };
  factory EmergencyContact.fromJson(Map<String, dynamic> json) =>
      EmergencyContact.validated(
        json['name'] as String,
        json['phone'] as String,
        json['relationship'] as String? ?? '',
      );
}

abstract class AccountAuth {
  bool get configured;
  String get configurationMessage;
  AccountIdentity? get current;
  Stream<AccountIdentity?> get changes;
  Future<AccountIdentity> signInGoogle();
  Future<void> reauthenticateGoogle();
  Future<void> signOut();
  Future<void> deleteUser();
}

abstract class AccountRepository {
  Future<void> ensureAccount(String uid, {required bool acceptTerms});
  Future<EmergencyContact?> readContact(String uid);
  Future<void> saveContact(String uid, EmergencyContact contact);
  Future<void> deleteContact(String uid);

  /// Leaves only a deletion guard without contact or profile information.
  Future<void> deletePhase3Data(String uid);
}

abstract class ContactCache {
  Future<EmergencyContact?> read(String uid);
  Future<void> write(String uid, EmergencyContact contact);
  Future<void> clear();
}

abstract class ContactDialer {
  Future<bool> dial(EmergencyContact contact);
}
