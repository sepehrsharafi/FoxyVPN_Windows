/// Current Firefox stable release. Keep this pinned and bump it by hand as
/// Firefox releases: signing in must not depend on a version lookup at startup.
const firefoxVersion = '159.0';

/// The identity used for every Firefox Accounts request. FxA's edge (Fastly)
/// refuses the MozillaVPN user agent on api.accounts.firefox.com with HTTP 406
/// as a whole class of client, so FxA sees one plain desktop Firefox instead.
/// It is the same on Windows and Android and never changes while the app runs,
/// so any cookies the edge hands out are always presented by the same client.
/// Guardian and the server list keep the MozillaVPN user agent.
final firefoxUserAgent = firefoxUserAgentFor(firefoxVersion);

String firefoxUserAgentFor(String version) {
  final major = version.split('.').first;
  return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:$major.0) Gecko/20100101 Firefox/$version';
}
