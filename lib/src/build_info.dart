/// Build metadata supplied by KURAKO's release scripts.
///
/// Flutter embeds `--dart-define` values into the compiled application, so the
/// timestamp describes the package being run rather than the time the settings
/// screen happened to be opened. A direct IDE/debug build intentionally shows
/// a clear fallback until it is built through one of the supplied scripts.
const String kBuildTime = String.fromEnvironment(
  'KURAKO_BUILD_TIME',
  defaultValue: '开发构建（未写入编译时间）',
);
