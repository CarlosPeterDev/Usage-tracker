import 'package:material_ui/material_ui.dart';
import 'feature_language.dart';

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key, this.firstLaunch = false, this.onContinue});
  final bool firstLaunch;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final sections = ar ? const [
      ('خصوصيتك مهمة', 'يعرض التطبيق إحصائيات استخدام الإنترنت التي يوفرها نظام أندرويد. لا يرسل التطبيق سجل استهلاكك إلى خادم تابع للمطور وفقًا لتصميمه الحالي.'),
      ('الأذونات', 'يُستخدم إذن الوصول إلى بيانات الاستخدام لعرض استهلاك الإنترنت لكل تطبيق. وقد يلزم إذن الهاتف على بعض إصدارات أندرويد للتعرف على شرائح الاتصال، وإذن الإشعارات لإرسال التنبيهات الاختيارية. يمكنك تعديل الأذونات من إعدادات الجهاز.'),
      ('البيانات المحلية', 'تُحفظ تفضيلاتك، ومنها حجم الباقة والتنبيهات واللغة والمظهر، محليًا على جهازك.'),
      ('الإعلانات وخدمات Google', 'يحتوي التطبيق على Google Mobile Ads. قد تجمع خدمات الإعلانات بيانات مثل معرّفات الجهاز والتفاعل مع الإعلانات ومعلومات التشخيص وعنوان IP لأغراض الإعلانات والأمان والقياس، حسب الإعدادات وسياسات Google. لذلك لا ندّعي عدم جمع أي بيانات بواسطة الجهات الخارجية.'),
      ('التحكم والشفافية', 'يمكنك إيقاف الأذونات من إعدادات أندرويد. راجع سياسة Google للإعلانات على policies.google.com/technologies/ads. هذه المعلومات لا تحل محل سياسة الخصوصية العامة المطلوبة في Google Play.'),
    ] : const [
      ('Your privacy matters', 'The app displays network usage statistics supplied by Android. Under its current design, it does not send your network usage history to a developer-operated server.'),
      ('Permissions', 'Usage Access is used to show per-app network consumption. Phone permission may be needed on some Android versions to identify SIM cards; notification permission is used for optional alerts. You can manage permissions in Android Settings.'),
      ('On-device settings', 'Preferences such as plan size, alert thresholds, language, and appearance are stored locally on your device.'),
      ('Google advertising', 'The app includes Google Mobile Ads. Advertising services may collect data such as device identifiers, ad interactions, diagnostics, and IP addresses for advertising, security, and measurement, depending on configuration and Google policies. We do not claim that third-party services collect no data.'),
      ('Your choices', 'You can revoke permissions in Android Settings. Learn about Google advertising at policies.google.com/technologies/ads. This notice does not replace the publicly hosted privacy policy required for Google Play.'),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Privacy & Data', 'الخصوصية والبيانات')),
        automaticallyImplyLeading: !firstLaunch),
      body: SafeArea(child: Column(children: [
        Expanded(child: ListView(padding: const EdgeInsets.all(20), children: [
          const Icon(Icons.shield_outlined, size: 48),
          const SizedBox(height: 12),
          for (final section in sections) ...[
            Text(section.$1, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(section.$2),
            const SizedBox(height: 20),
          ],
        ])),
        if (firstLaunch) Padding(padding: const EdgeInsets.all(16),
          child: SizedBox(width: double.infinity, child: FilledButton(
            onPressed: onContinue,
            child: Text(tr(context, 'Continue', 'متابعة')),
          ))),
      ])),
    );
  }
}
