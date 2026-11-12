# Third-party notices

The root MIT license covers Matt Kelly's original work. It does not replace third-party copyright or license terms.

| Material | Where used | Notice |
| --- | --- | --- |
| BearSSL, Thomas Pornin | Attributed AES bitslice and GHASH ports in std/core/crypto/aes.qz and aes_gcm.qz | [MIT license](licenses/BearSSL.txt); [upstream](https://www.bearssl.org/) |
| dudect, Oscar Reparaz | Statistical timing-leak harness in std/crypto/dudect.qz | [MIT license](licenses/dudect.txt); [upstream](https://github.com/oreparaz/dudect) |
| TweetNaCl / ref10 algorithms | Attributed Ed25519 scalar/group routines | [TweetNaCl](https://tweetnacl.cr.yp.to/) identifies its implementation as public domain; attribution remains in source. |
| Quartz editor extension contributors | editors/vscode | [Retained extension license](editors/vscode/LICENSE) |

LLVM, Clang, system libraries and OpenSSL are external toolchain/dependency components, not relicensed or vendored by this repository. Their own terms apply when installing or distributing them.

The hyper bouba port and bundled CHIP-8 game ROMs have been excluded because this review did not establish redistribution permission. Source references to them are historical, not an offer to distribute those assets.
