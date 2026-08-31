# Documentation publication checklist

This page is for the documentation publishing workflow and should not be exposed as a primary
customer procedure unless the Help information architecture requires it.

## Content finalization

- [ ] Replace `<operator-version>`, `<release-tag>`, `<saia-version>`, and `<slim-version>` with
      release-approved values.
- [ ] Confirm the Kubernetes, Helm, GPU, storage, and Splunk compatibility requirements.
- [ ] Confirm that storage examples are limited to the release-tested AWS S3 and S3-compatible
      backends.
- [ ] Confirm chart and manifest URLs for the release.
- [ ] Confirm the required Splunk General Terms wording and link.
- [ ] Add the approved MLTK installation and configuration links.
- [ ] Confirm SAIA V1 and V2 endpoint paths, service ports, and Agent mode behavior.
- [ ] Confirm the AI-tier internal and external Splunk integration procedures.
- [ ] Confirm the SOCKS proxy guidance with the networking owner.

## Link and command validation

- [ ] Test every internal Help link after the page hierarchy is created.
- [ ] Test installation commands against the release artifacts.
- [ ] Test standard and air-gapped installation procedures.
- [ ] Test status, log, connectivity, and troubleshooting commands.
- [ ] Verify that examples do not contain real credentials, tokens, private host names, or keys.

## SAIA UI dependency

Use a stable AI-tier Help landing-page URL for onboarding links. If the final installation page is
not live at SAIA release time, point the stable URL to an approved temporary page or hide the link
behind a release/configuration flag. Do not ship an unverified deep link tied only to a planned GA
date.

## Review and ownership

- [ ] Product owner review completed.
- [ ] Operator engineering review completed.
- [ ] SAIA V1/V2 engineering review completed.
- [ ] Splunk integration and MLTK owners reviewed the relevant pages.
- [ ] Security and networking review completed.
- [ ] Support team has the final troubleshooting and diagnostics guidance.
