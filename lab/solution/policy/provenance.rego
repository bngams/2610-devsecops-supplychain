package signature

# Politique évaluée par : cosign verify-attestation --type slsaprovenance1 --policy policy/provenance.rego
# "input" = la déclaration in-toto signée (predicateType + predicate).
# La vérification échoue si "allow" vaut false.

default allow = false

# sources de pipeline acceptées : un push, ou le bouton "Run pipeline" (web)
allowed_sources := {"push", "web"}

allow {
  input.predicateType == "https://slsa.dev/provenance/v1"
  # l'image doit venir de NOTRE projet... (adaptez le chemin à votre projet)
  input.predicate.buildDefinition.externalParameters.source == "https://gitlab.com/bngams/pipeline-sast-cicd-nb-2610"
  # ...construite depuis la branche main...
  input.predicate.buildDefinition.externalParameters.ref == "main"
  # ...par un pipeline déclenché par un push ou à la main (pas par l'API ou un trigger)
  allowed_sources[input.predicate.buildDefinition.externalParameters.variables.CI_PIPELINE_SOURCE]
}
