# Documentation publication checklist

This page is for the internal documentation publishing workflow. Do not publish it in customer
Help.

## Content finalization

- [x] Confirm that the v1.0.0 OCI chart and release-package URLs resolve to the approved artifacts.
- [ ] Correct the published v1.0.0 chart's embedded Ray and SAIA image defaults and expose a
      `rayVersion` value set to `2.56.0`. Until a corrected chart is published, keep direct chart
      installation explicitly unsupported in customer Help.
- [ ] Confirm the Kubernetes, Helm, GPU, storage, and Splunk compatibility requirements.
- [ ] Confirm that storage examples are limited to the release-tested AWS S3 and S3-compatible
      backends.
- [ ] Confirm the required Splunk General Terms wording and link.
- [ ] Add an explicit Terms-acceptance gate to each installer, or obtain Legal approval for the
      bundled manifest's current non-interactive acceptance behavior and customer wording.
- [ ] Confirm that Splunk AI Assistant app version 2.3.0 is published and downloadable from the
      linked Splunkbase page.
- [ ] Add the approved MLTK installation and configuration links.
- [ ] Confirm SAIA v1/v2 internal API routing, front-door Service ports, and browser-access behavior.
- [ ] Confirm the AI-tier internal and external Splunk integration procedures.
- [ ] Confirm the SOCKS proxy guidance with the networking owner.
- [ ] Obtain Security and Product approval for the documented static object-storage credential
      snapshot into generated Ray configuration, or fix the implementation before publication.
- [ ] Confirm that the publishing system preserves or replaces links from Help to the k0s and
      OpenShift deployment guides.
- [ ] Replace the OpenShift sample configuration's development images with the qualified release
      combination; until then, retain the required overrides in customer Help.

## Link and command validation

- [ ] Test every internal Help link after the page hierarchy is created.
- [ ] Test installation commands against the release artifacts.
- [ ] Test installation on a clean cluster, including dependency CRDs and controllers.
- [ ] Test standard and air-gapped installation procedures.
- [ ] Verify that the air-gapped inventory includes every dependency, hook, operator, and workload
      image.
- [ ] Verify all rendered workload images and confirm that no private or unqualified references
      remain.
- [ ] Verify workload namespaces, referenced Secrets, and default or pre-created ServiceAccounts.
- [ ] Test any release-supported CRD or service-image maintenance procedure with the selected
      platform installer and corrected release artifacts.
- [ ] Test status, log, connectivity, and troubleshooting commands.
- [ ] Confirm that every label selector in a command returns the intended pods.
- [ ] Verify that examples do not contain real credentials, tokens, private host names, or keys.

## SAIA UI dependency

Use a stable AI-tier Help landing-page URL for onboarding links. If the final installation page is
not live at SAIA release time, point the stable URL to an approved temporary page or hide the link
behind a release/configuration flag. Do not ship an unverified deep link tied only to a planned GA
date.

## Review and ownership

- [ ] Product owner review completed.
- [ ] Operator engineering review completed.
- [ ] SAIA v1/v2 internal-routing engineering review completed.
- [ ] Splunk integration and MLTK owners reviewed the relevant pages.
- [ ] Security and networking review completed.
- [ ] Support team has the final troubleshooting and diagnostics guidance.
