import '../core/config/shipway_config.dart';
import '../core/managed/comment_style.dart';
import '../core/model/android_model.dart';
import '../core/managed/lock_file.dart';
import '../core/secrets/secret_names.dart';
import 'write_guards.dart';

/// Where to put a managed block in a file shipway does not own outright.
///
/// Declarative rather than a callback so a generator stays a pure function and
/// its output can be compared in a golden test.
class BlockAnchor {
  const BlockAnchor({required this.insideBlock, this.atEnd = false});

  /// Name of the enclosing brace-matched block to insert into, e.g. `android`.
  final String insideBlock;

  /// Insert just before the block's closing brace rather than just after its
  /// opening one.
  final bool atEnd;
}

/// One file a generator wants written.
class GeneratedFile {
  const GeneratedFile({
    required this.path,
    required this.contents,
    required this.mode,
    CommentStyle? commentStyle,
    this.anchor,
    this.description,
    this.createOnly = false,
    this.reconciler,
    this.guard,
  }) : _commentStyle = commentStyle;

  /// Fully-managed file: shipway owns the whole thing.
  const GeneratedFile.full({
    required String path,
    required String contents,
    String? description,
    WriteGuard? guard,
  }) : this(
         path: path,
         contents: contents,
         mode: WriteMode.full,
         description: description,
         guard: guard,
       );

  /// Written once if missing, then never touched again.
  ///
  /// For scaffolding a user is meant to fill in — a shared bootstrap, a
  /// starting point. shipway must create it so the generated entrypoints
  /// compile, and must never overwrite it, because by the second run it
  /// contains their code.
  const GeneratedFile.scaffold({
    required String path,
    required String contents,
    String? description,
  }) : this(
         path: path,
         contents: contents,
         mode: WriteMode.full,
         description: description,
         createOnly: true,
       );

  /// Block-managed file: shipway owns only the marked region.
  const GeneratedFile.block({
    required String path,
    required String contents,
    BlockAnchor? anchor,
    CommentStyle? commentStyle,
    String? description,
    ContentReconciler? reconciler,
  }) : this(
         path: path,
         contents: contents,
         mode: WriteMode.block,
         anchor: anchor,
         commentStyle: commentStyle,
         description: description,
         reconciler: reconciler,
       );

  /// Path relative to the project root, always POSIX-separated.
  final String path;

  /// The whole file for [WriteMode.full]; the block body for
  /// [WriteMode.block].
  final String contents;

  final WriteMode mode;

  final CommentStyle? _commentStyle;

  /// Comment syntax for the managed markers, defaulting to the one this file
  /// type conventionally uses.
  CommentStyle get commentStyle => _commentStyle ?? CommentStyle.forPath(path);

  /// Where a new block goes. Null means append to the end of the file.
  final BlockAnchor? anchor;

  /// One line for `--dry-run`, saying what this file is for.
  final String? description;

  /// Create if absent, then leave alone forever.
  final bool createOnly;

  /// Block files only: rewrites what the file already declares, so the block
  /// takes over from it instead of repeating it.
  final ContentReconciler? reconciler;

  /// A condition elsewhere in the project that must hold for this file to
  /// compile. Checked before anything is written.
  final WriteGuard? guard;
}

/// Turns configuration into files.
///
/// Pure: no I/O, no processes, no clock. That is what makes golden testing
/// trivial and what keeps the decision of *what* to write separate from the far
/// more delicate question of *whether* shipway is allowed to write it.
abstract class Generator {
  /// Subclasses are const singletons, so the base needs a const constructor.
  const Generator();

  /// Stable identifier, used by `shipway generate <name>`.
  String get name;

  /// One line describing what this generator produces.
  String get description;

  List<GeneratedFile> render(ResolvedApp app);

  /// Whether [path] is one this generator is responsible for.
  ///
  /// A predicate rather than a list, because the point is to recognise files
  /// belonging to flavors that are *no longer in the config* — whose names
  /// cannot be enumerated from it. Used only to decide whether a file shipway
  /// once generated and no longer produces is this generator's to clean up.
  ///
  /// Defaults to owning nothing: a generator opts in to having its leftovers
  /// swept, so adding one cannot accidentally start deleting files.
  bool owns(String path) => false;

  /// Whether this generator's silence means the config no longer asks for
  /// something.
  ///
  /// False when it could not run for reasons unrelated to the config — a
  /// missing template it copies from, say. Producing nothing is then not
  /// evidence of removal, and cleanup is suppressed rather than guessed at.
  bool canDetermineOwnership(ResolvedApp app) => true;
}

/// A config narrowed to one app, with the values every generator needs already
/// resolved.
///
/// Generators receive this rather than the raw config so that the rules about
/// defaults — an entrypoint's conventional path, a flavor's effective bundle
/// id — are applied once, here, instead of being re-derived slightly
/// differently by each generator.
class ResolvedApp {
  const ResolvedApp({
    required this.appId,
    required this.projectName,
    required this.flavors,
    required this.androidApplicationId,
    required this.iosBundleId,
    required this.gradleDsl,
    this.iosTeamId,
    this.iosSchemeTemplate,
    this.iosExport = IosExport.gym,
    this.matchGitUrl,
    this.matchStorage = MatchStorage.git,
    this.ascApiKey,
    this.testflight,
    this.play,
    this.firebase,
    this.androidSigning,
    this.shipsIos = true,
    this.versioning = const VersioningConfig(),
    this.appstore,
  });

  final String appId;
  final String projectName;

  /// In declaration order, which is the order they are written in.
  final List<ResolvedFlavor> flavors;

  /// Unsuffixed Android application id, or null when the config does not say.
  final String? androidApplicationId;

  /// Unsuffixed iOS bundle id, or null when the config does not say.
  final String? iosBundleId;

  /// Which dialect the Android generator must emit.
  final GradleDsl gradleDsl;

  final String? iosTeamId;

  /// The project's existing `Runner.xcscheme`, used as the basis for every
  /// generated scheme.
  ///
  /// Carried on the resolved app rather than read by the generator so the
  /// generator stays pure, and so a project with no readable scheme produces no
  /// schemes instead of broken ones.
  final String? iosSchemeTemplate;

  /// Which tool exports the `.ipa`; decides the shape of the build lane.
  final IosExport iosExport;

  final String? matchGitUrl;
  final MatchStorage matchStorage;

  /// App Store Connect key, by reference only — never a value.
  final AscApiKeyConfig? ascApiKey;

  /// Deploy targets, when the config declares them. Null means the generated
  /// lane falls back to a safe default rather than inventing a destination.
  final TestflightTarget? testflight;
  final PlayTarget? play;
  final FirebaseTarget? firebase;

  final AndroidSigningConfig? androidSigning;

  /// How a release picks its build number.
  final VersioningConfig versioning;

  final AppstoreTarget? appstore;

  /// Whether this app ships to Apple. Carried from `AppConfig.shipsIos` so the
  /// generators and the pre-flight cannot answer it differently.
  final bool shipsIos;

  bool get hasFlavors => flavors.isNotEmpty;

  /// The variable naming [flavor]'s Android app id, or null when it comes
  /// from the flavor's `google-services.json`. The same rule as
  /// `AppConfig.firebaseAndroidAppIdVariable`, which the pre-flight uses.
  String? firebaseAndroidAppIdVariable(ResolvedFlavor flavor) =>
      flavor.firebaseAndroidAppIdRef ?? firebase?.androidAppIdRef;

  ResolvedFlavor? flavor(String name) {
    for (final flavor in flavors) {
      if (flavor.name == name) return flavor;
    }
    return null;
  }
}

/// One flavor with every derived value already computed.
class ResolvedFlavor {
  const ResolvedFlavor({
    required this.name,
    required this.suffix,
    required this.entrypoint,
    required this.dimension,
    this.versionNameSuffix,
    this.displayName,
    this.dartDefines = const <String, String>{},
    this.androidApplicationId,
    this.iosBundleId,
    this.firebaseAndroid,
    this.firebaseIos,
    this.firebaseServiceAccountRef,
    this.firebaseAndroidAppIdRef,
  });

  final String name;

  /// Appended to the base id. Empty for the production flavor.
  final String suffix;

  /// Path to this flavor's Dart entrypoint, defaulted if the config is silent.
  final String entrypoint;

  final String dimension;
  final String? versionNameSuffix;
  final String? displayName;
  final Map<String, String> dartDefines;

  /// Full application id for this flavor, null when the base is unknown.
  final String? androidApplicationId;

  final String? iosBundleId;

  final String? firebaseAndroid;
  final String? firebaseIos;

  /// `flavors.<name>.firebase.distribution`, as written — null when the
  /// flavor uses the defaults.
  final String? firebaseServiceAccountRef;
  final String? firebaseAndroidAppIdRef;

  /// The variable holding the path to this flavor's service account.
  String get firebaseServiceAccountVariable =>
      firebaseServiceAccountRef ?? SecretNames.firebaseServiceAccountPath;

  /// The iOS build configuration names this flavor requires.
  List<String> get iosConfigurations => <String>[
    'Debug-$name',
    'Release-$name',
    'Profile-$name',
  ];

  /// The display name, falling back to something sensible rather than null so
  /// generated resources never contain an empty string.
  String displayNameOr(String projectName) =>
      displayName ?? (suffix.isEmpty ? projectName : '$projectName $name');
}
