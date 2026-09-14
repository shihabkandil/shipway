import '../core/config/shipway_config.dart';
import '../core/env/run_environment.dart';
import '../core/secrets/secret_names.dart';
import 'secret_requirements.dart';

/// One secret to set on the CI repository, and what wants it.
class RepositorySecret {
  const RepositorySecret({required this.name, required this.wantedBy});

  final String name;

  /// Why it is on the list, carried through so the script answers "what is
  /// this for?" without a second document.
  final String wantedBy;
}

/// The repository secrets a CI run of this config needs.
///
/// Derived for [RunEnvironment.ephemeralCi] whatever machine shipway is running
/// on, because the thing being wired up is the runner rather than this laptop.
/// The workstation's list would name an interactive Apple ID nobody should set
/// on CI and omit the match credential the clone cannot work without.
///
/// Two names are swapped on the way out. A path-valued variable is not
/// something you can put in GitHub — the workflow writes the file and points
/// the variable at it — so what is named here is the secret supplying its
/// *content*. That mapping lives with the names, beside the workflow that
/// relies on it.
abstract final class RepositorySecrets {
  static List<RepositorySecret> of(ShipwayConfig config, {String? appId}) {
    final byName = <String, RepositorySecret>{};
    for (final requirement in SecretRequirements.of(
      config,
      environment: RunEnvironment.ephemeralCi,
      appId: appId,
    )) {
      // Optional ones are overrides. Telling someone to set eleven secrets
      // when six are needed is how a checklist stops being read.
      if (!requirement.isRequired) continue;

      final name = requirement.isPath
          ? SecretNames.contentSecretFor(requirement.name)
          : requirement.name;
      byName.putIfAbsent(
        name,
        () => RepositorySecret(
          name: name,
          wantedBy: requirement.isPath && name != requirement.name
              ? '${requirement.wantedBy}; the workflow writes it to a file '
                    'and sets ${requirement.name}'
              : requirement.wantedBy,
        ),
      );
    }
    final secrets = byName.values.toList();
    secrets.sort((a, b) => a.name.compareTo(b.name));
    return secrets;
  }
}
