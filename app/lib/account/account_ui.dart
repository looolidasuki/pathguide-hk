import '../l10n/app_language.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_controller.dart';
import 'account_models.dart';
import '../photos/photo_ui.dart';

class AccountScope extends InheritedNotifier<AccountController> {
  const AccountScope({
    super.key,
    required AccountController controller,
    required super.child,
  }) : super(notifier: controller);
  static AccountController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AccountScope>()!.notifier!;
}

class AccountEntry extends StatelessWidget {
  const AccountEntry({super.key, required this.onManage});
  final VoidCallback onManage;
  @override
  Widget build(BuildContext context) {
    final account = AccountScope.of(context);
    final contact = account.contact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (contact != null && !account.deletionPending) ...[
          Semantics(
            label: context.tr('聯絡 ${contact.name}，電話 ${contact.phone}，開啟系統撥號'),
            button: true,
            enabled: account.canCallContact,
            excludeSemantics: true,
            onTap: account.canCallContact ? account.callContact : null,
            child: FilledButton.icon(
              key: const ValueKey('call-emergency-contact'),
              onPressed: account.canCallContact ? account.callContact : null,
              icon: const Icon(Icons.phone_outlined),
              label: AppText('聯絡 ${contact.name}'),
            ),
          ),
          const SizedBox(height: 8),
          if (account.message?.contains('撥號') ?? false)
            Semantics(liveRegion: true, child: AppText(account.message!)),
        ],
        OutlinedButton.icon(
          key: const ValueKey('manage-account'),
          onPressed: onManage,
          icon: const Icon(Icons.person_outline),
          label: AppText(
            account.identity == null ? 'Google 登入與緊急聯絡人' : '帳號與緊急聯絡人',
          ),
        ),
      ],
    );
  }
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.onBack});
  final VoidCallback onBack;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool _terms = false;
  Future<void> _edit(AccountController account) => Navigator.of(context)
      .push<void>(
        MaterialPageRoute(builder: (_) => ContactEditor(account: account)),
      );
  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: AppText(title),
          content: AppText(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const AppText('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const AppText('確認刪除'),
            ),
          ],
        ),
      ) ??
      false;
  @override
  Widget build(BuildContext context) {
    final account = AccountScope.of(context);
    final user = account.identity;
    final contact = account.contact;
    return Scaffold(
      appBar: AppBar(
        title: const AppText('帳號與緊急聯絡人'),
        leading: IconButton(
          tooltip: context.tr('返回原任務'),
          constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (account.busy)
            const LinearProgressIndicator(semanticsLabel: '正在處理帳號'),
          if (account.message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Semantics(
                liveRegion: true,
                child: AppText(
                  account.message!,
                  key: const ValueKey('account-message'),
                ),
              ),
            ),
          if (!account.configured) ...[
            AppText(account.auth.configurationMessage),
            const SizedBox(height: 16),
          ],
          if (user == null ||
              (!account.profileReady && !account.deletionPending)) ...[
            const AppText('基本辨識毋須登入。Google 帳號用於保存你的設定與緊急聯絡人，以及日後的私人資料歸屬。'),
            const SizedBox(height: 12),
            const AppText(
              '登入會使用 Google／Firebase 處理帳號識別資料。緊急聯絡人另存於私人資料，不加入模型訓練。照片收集須另外配置及同意，亦不會因登入而啟用。',
            ),
            CheckboxListTile(
              key: const ValueKey('account-terms'),
              contentPadding: EdgeInsets.zero,
              title: const AppText('我已閱讀並同意上述帳號用途說明'),
              value: _terms,
              onChanged: account.busy
                  ? null
                  : (value) => setState(() => _terms = value ?? false),
            ),
            if (user == null)
              FilledButton(
                key: const ValueKey('google-sign-in'),
                onPressed: account.busy || !account.configured
                    ? null
                    : () => account.signIn(acceptTerms: _terms),
                child: const AppText('使用 Google 登入'),
              )
            else
              FilledButton(
                onPressed: account.busy
                    ? null
                    : () => account.retryProfile(acceptTerms: _terms),
                child: const AppText('重試／完成帳號設定'),
              ),
          ],
          if (user != null) ...[
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: AppText(
                user.name ?? 'Google 帳號',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (user.email != null) AppText(user.email!),
            if (account.deletionPending)
              const AppText('帳號刪除待完成，聯絡資料及新寫入已停用。請重試刪除。'),
            if (account.profileReady && !account.deletionPending) ...[
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: AppText(
                  '緊急聯絡人（選填）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              AppText(
                contact == null
                    ? '尚未設定，可以稍後再填。'
                    : '${contact.name}\n${contact.phone}${contact.relationship.isEmpty ? '' : '\n${contact.relationship}'}',
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('edit-contact'),
                onPressed: account.busy ? null : () => _edit(account),
                child: AppText(contact == null ? '新增緊急聯絡人' : '修改緊急聯絡人'),
              ),
              if (contact != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  button: true,
                  excludeSemantics: true,
                  label: context.tr(
                    '聯絡 ${contact.name}，電話 ${contact.phone}，開啟系統撥號',
                  ),
                  onTap: account.canCallContact ? account.callContact : null,
                  child: OutlinedButton(
                    onPressed: account.canCallContact
                        ? account.callContact
                        : null,
                    child: AppText('聯絡 ${contact.name}'),
                  ),
                ),
                TextButton(
                  onPressed: account.busy
                      ? null
                      : () async {
                          if (await _confirm(
                                '刪除緊急聯絡人',
                                '刪除雲端聯絡資料及這部手機的離線副本？',
                              ) &&
                              account.identity?.uid == user.uid) {
                            await account.removeContact();
                          }
                        },
                  child: const AppText('刪除緊急聯絡人'),
                ),
              ],
              if (account.offerContactSetup)
                TextButton(
                  key: const ValueKey('skip-contact'),
                  onPressed: () {
                    account.skipContactSetup();
                    widget.onBack();
                  },
                  child: const AppText('稍後設定，返回原任務'),
                ),
              const SizedBox(height: 16),
              const AppText('聯絡按鈕只開啟系統撥號，不會自動發送短訊或位置，亦不代表對方已接聽。'),
              const SizedBox(height: 16),
              const PhotoEntry(),
              const AppText('目前使用內置模型；照片須另行同意及配置雲端服務。私人訓練及個人模型下載尚未接入。'),
            ],
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: account.busy ? null : account.signOut,
              child: const AppText('登出'),
            ),
            TextButton(
              key: const ValueKey('delete-account'),
              onPressed: account.busy
                  ? null
                  : () async {
                      if (await _confirm(
                            '刪除帳號',
                            '將重新驗證同一 Google 帳號，刪除帳號及本階段的私人聯絡資料。你仍可使用訪客辨識。',
                          ) &&
                          account.identity?.uid == user.uid) {
                        await account.deleteAccount();
                      }
                    },
              child: AppText(account.deletionPending ? '重試刪除帳號' : '刪除帳號'),
            ),
          ],
          const SizedBox(height: 16),
          TextButton(
            onPressed: widget.onBack,
            child: const AppText('返回原任務，使用基本辨識'),
          ),
        ],
      ),
    );
  }
}

class ContactEditor extends StatefulWidget {
  const ContactEditor({super.key, required this.account});
  final AccountController account;
  @override
  State<ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<ContactEditor> {
  late final _name = TextEditingController(text: widget.account.contact?.name);
  late final _phone = TextEditingController(
    text: widget.account.contact?.phone,
  );
  late final _relationship = TextEditingController(
    text: widget.account.contact?.relationship,
  );
  String? _error;
  late final String? _initialMessage = widget.account.message;
  late final String? _owner = widget.account.identity?.uid;
  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relationship.dispose();
    super.dispose();
  }

  Widget _field(String label, TextField field) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ExcludeSemantics(child: AppText(label)),
      const SizedBox(height: 8),
      Semantics(label: context.tr(label), child: field),
      const SizedBox(height: 16),
    ],
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.account,
    builder: (context, _) {
      final current = widget.account.identity?.uid == _owner && _owner != null;
      if (!current) {
        return Scaffold(
          appBar: AppBar(title: const AppText('帳號已變更')),
          body: const Padding(
            padding: EdgeInsets.all(20),
            child: AppText('請返回原任務，再使用目前帳號設定聯絡人。'),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const AppText('設定緊急聯絡人')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const AppText('只需一位聯絡人。請先取得對方同意；資料只供你的聯絡功能使用，不加入訓練資料。'),
            const SizedBox(height: 16),
            _field(
              '聯絡人稱呼（必填）',
              TextField(
                key: const ValueKey('contact-name'),
                controller: _name,
                maxLength: 60,
                enabled: !widget.account.busy,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(border: OutlineInputBorder()),
              ),
            ),
            _field(
              '電話號碼（必填）',
              TextField(
                key: const ValueKey('contact-phone'),
                controller: _phone,
                enabled: !widget.account.busy,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  helperText: '香港八位數，或附國際區號，例如 +852',
                  helperMaxLines: 3,
                ),
              ),
            ),
            _field(
              '關係（選填）',
              TextField(
                key: const ValueKey('contact-relationship'),
                controller: _relationship,
                maxLength: 30,
                enabled: !widget.account.busy,
                decoration: InputDecoration(border: OutlineInputBorder()),
              ),
            ),
            if (_error != null ||
                (widget.account.message != null &&
                    widget.account.message != _initialMessage))
              Semantics(
                liveRegion: true,
                child: AppText(_error ?? widget.account.message!),
              ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('save-contact'),
              onPressed: !current || widget.account.busy
                  ? null
                  : () async {
                      try {
                        final contact = EmergencyContact.validated(
                          _name.text,
                          _phone.text,
                          _relationship.text,
                        );
                        setState(() => _error = null);
                        TextInput.finishAutofillContext();
                        if (await widget.account.saveContact(contact) &&
                            context.mounted) {
                          Navigator.pop(context);
                        }
                      } on AccountFailure catch (error) {
                        setState(() => _error = error.message);
                      }
                    },
              child: const AppText('儲存聯絡人'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const AppText('取消，不儲存'),
            ),
          ],
        ),
      );
    },
  );
}
