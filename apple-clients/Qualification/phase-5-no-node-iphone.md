# iPhone with no node: PHI verification (T5.9 live run, T8.7)

The automated part is `AstralAppTests/MeshPhiNoNodeTests`, run on an iOS simulator against a real Kernel. This file lists the live steps that still need a real iPhone and a real Mac.

## Setup
- A mesh with an iPhone and a Mac and no node. The Mac updated to the same Kernel build.
- A model provider on the iPhone at an HTTPS address that is not approved for PHI.
- Apple Intelligence on for one run and off for another.

## Steps
1. Open the PHI group card on the iPhone and set up PHI. Record how many Touch ID or Face ID prompts appear and whether one covers the batch.
2. Send clinical-looking text (a name, a date of birth and a record number). Expect the message to carry the PHI label and the answer to come from the on-device model, or a refusal that offers the approval card when no on-device model is available.
3. Open the approval card for the provider. Check the name, address and the three plain facts. Approve once and check the presence prompt.
4. Send the same text again. Expect the turn to reach the provider.
5. Send text with only a date. In the foreground expect the question sheet. Answer Send, then repeat and answer Treat as PHI. Check the labels.
6. Background the app during a question and expect Treat as PHI.
7. Send the same date text from the Watch. Expect no sheet and the PHI label.
8. Repeat steps 2 and 5 with Apple Intelligence off. The floor alone decides and the status says no model.
9. Exclude the Mac from the PHI group. Check the card says data already on it stays, and that the Mac refuses PHI writes.

## Record
Device, OS, build, Kernel commit, result per step, screenshots.
