# Mesh device controls

AstralDeep owns the Mesh devices surface, authorization, signed owner-session
custody, confirmation and durable audit. Projection renders the shared forms and
keeps a joining device's signing key local. The shared manifest separates six
server management actions from `chrome_mesh_identity` and `chrome_mesh_redeem`,
which clients intercept locally. These local actions never become socket events.

On the joining device, create a request with the optional other-device identity
left empty. The client generates a persistent Ed25519 key and sends only its
canonical public JWK. Another signed-in owner device confirms the displayed
fingerprint. Return the one-time current-server `/enroll#payload` link to the
original joining device to complete enrollment. The joining device can instead
copy its public identity for an owner device to create its request. A copied
grant cannot enroll a device holding a different key.

Web uses a nonextractable CryptoKey in server/account-scoped IndexedDB. Windows
uses current-user DPAPI, Apple uses ThisDeviceOnly Keychain storage, and Android
uses its existing encrypted preferences with the pinned Tink Ed25519 provider.
Normal shutdown preserves the private key. Explicit signout, account replacement
or server replacement retires custody. Watch uses the existing generic form
handoff to a signed-in phone or desktop; neither private keys nor grants are
forwarded through the watch.

Clients sign the exact decoded 32-byte challenge and redeem through the existing
REST endpoint. Before storing a public member ID or displaying success, each
client obtains a fresh nonce and verifies the active owner/member/key through a
cookie-free DPoP `/api/mesh/me` request. The resulting member token stays in
memory and is discarded. Native owner management continues to use normal PKCE
and the server-issued signed owner cookie; this feature does not add native
member tool transport.

Links and bearer tokens are never persisted, queued or reconnect-replayed.
Owner, connection, surface and request retirement cancel pending work. If the
grant was consumed but final verification or local persistence failed, check
Mesh devices and revoke/reissue as needed; the client must not claim success.
The dedicated web page removes its fragment before loading external assets and
uses host-issued CSP and no-store headers. Its scripts stay outside the public
offline cache.

Tests cover separate device keys, exact challenge and DPoP signatures, missing
or damaged custody, wrong owners/servers/keys, bounded replies, denied grants,
stale UI responses, account changes, and cancellation during persistence. Live
qualification must use the exact Projection pin with the host's real dispatcher
and Keycloak staging; synthetic boundary tests do not replace those receipts.
