# Spam rule references

Reviewed on 2026-10-01. These references inform the local filtering design; they do not establish detection accuracy or grant access to commercial caller-identification services.

## SMS design

| Reference | Relevant approach |
| --- | --- |
| [SMSGuard](https://github.com/boommanpro/ios-sms-guard) | Chinese keyword rules, message categories, editable presets and local test inputs. |
| [Simply Filter SMS](https://github.com/adibendahan/SimplyFilterSMS-iOS) | User-controlled allow/deny keyword and regular-expression filters. |
| [CallShield](https://github.com/SysAdminDoc/CallShield) | Exact-number lists, local overrides and external list subscriptions. |

CallRelay's small SMS presets are independently authored. Loan solicitation, gambling/task scams, promotional unsubscribe language and English promotions are separate configurable groups. Unknown senders, ordinary 106 senders and genuine verification/transaction notices are not blanket junk categories. Any bundled third-party data keeps its own license.

## Chinese call lists

[blessing-gao/rubbish-phone](https://github.com/blessing-gao/rubbish-phone) contains a small community-reported real-estate marketing list: 34 unique complete Chinese mobile numbers in `房地产垃圾电话.md`. The file was last changed on 2020-06-21 at [commit 926dc0f](https://github.com/blessing-gao/rubbish-phone/commit/926dc0fcd2a36d783289b6499fdf0202f8383a41). Its repository uses Apache-2.0. It is a historical community list, not a current, complete or independently verified Chinese spam database. If offered in the app, it starts disabled and exposes its source, date and count. The repository's unrelated retaliation features are outside CallRelay's scope.

[BanHarassment](https://github.com/vlongen/BanHarassment) was reviewed but is unsuitable as a default list: it blocks all landline area codes and several ordinary mobile prefixes. Its repository has no identified license and was last pushed in 2023. It is not bundled or automatically subscribed.

[parasol-tree/harassmentCall](https://github.com/parasol-tree/harassmentCall) was also inspected. Its `carrier_data_*` and `landlinePhone.json` files describe ordinary number geography and carrier assignments. Those files are not evidence that the corresponding numbers are spam. [beingbin/crank-call](https://github.com/beingbin/crank-call) contains an old company address book, which is not suitable for a spam preset.

## Delivery boundaries

Local rules and lists apply to the owned gateway's calls and messages in CallRelay. They do not install a filter for the iPhone's separate cellular SIM. Client-side call rejection must respect CallKit/PushKit reporting requirements; a server-side rejection before notification requires a gateway capability actually supported by the deployed server. Downloaded list updates must preserve the last valid version on failure. Users can override a match with a white list and review quarantined messages or call records.
