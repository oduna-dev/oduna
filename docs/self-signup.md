# Self-signup for allowed e-mail domains

> **Status:** planned, not implemented. Today every identity-provider user is
> created by an admin by hand.

## Goal

A person with an address on an allowed domain signs up on the identity
provider's login page, confirms the address by e-mail, picks a password and can
then sign in to every app through SSO. No admin step, no open registration.

## Scope

- The allowed domains are an instance option, for example
  `homelab.identity.signupDomains = [ "example.org" ]`. The empty default means
  no self-signup, the current behavior.
- Converge creates and repairs the enrollment objects idempotently, like the
  groups and providers it already manages. The objects are an enrollment flow, a
  policy that checks the domain, and the link on the login page.
- Out of scope: invitations for other domains, approval queues, social logins.

## Design

The flow has four stages in this order:

1. **Prompt:** username, name, e-mail, password with confirmation.
2. **Domain policy:** an expression policy bound to the prompt stage rejects any
   address whose domain is not in the allowed list. The list reaches the policy
   through converge, never through a hand-edited expression.
3. **E-mail verification:** a mail with a one-time link. The user stays inactive
   until it is used.
4. **User write:** creates the user inactive, then activates it after
   verification, and adds it to the app-access group (never to `admins`).

The flow is attached to the login page's identification stage, which adds the
"Sign up" link. A recovery flow (password reset by e-mail) belongs with it, so a
user who forgot the password can pick a new one without an admin; it uses the
same e-mail stage.

## Decisions

- **Verification is mandatory.** A domain check alone lets anyone type an
  address they do not own.
- **No privileges by default.** Self-signed-up users are plain app users. The
  app-owner roles (the first OpenID login in Actual Budget, the admin accounts
  of the other apps) are not reachable this way.
- **Every allowed-domain user gets access to every app** that trusts the IdP
  group. Instances that need per-app limits bind groups to applications.

## Open questions

- Whether a user may change the e-mail address after signup. Apps that key
  accounts on the address (Vaultwarden) would then lose the link.
- Rate limiting of the signup and verification mails against abuse.
- How the VM test covers the flow, since it has neither a mail relay nor real
  DNS; probably only that the objects exist and the policy rejects a foreign
  domain.

## Verification plan

On a live instance: sign up with an allowed address, confirm the mail, sign in
to two apps; sign up with a foreign domain and see it rejected; remove the
option and see that converge removes the link.
