<#--
  homelab login theme — override of keycloak.v2 webauthn-register.ftl.

  Stock Keycloak fires a window.prompt() asking the user to name the passkey right
  after it's created (in webauthnRegister.js -> returnSuccess). Users found that
  confusing. We don't touch the JS (upgrade-safe); we just neutralize window.prompt
  before registration runs, so returnSuccess() sees a null result and falls back to
  the default label (msg "webauthn-registration-init-label", overridden to "Passkey").
  Net effect: passkey is created and the form auto-submits with no label dialog.
-->
<#import "template.ftl" as layout>
<#import "password-commons.ftl" as passwordCommons>
<#import "buttons.ftl" as buttons>

<@layout.registrationLayout; section>
    <#if section = "title">
        title
    <#elseif section = "header">
        ${msg("webauthn-registration-title")}
    <#elseif section = "form">
    <div class="${properties.kcFormClass!}">
        <form id="register" action="${url.loginAction}" method="post" >
            <div class="${properties.kcFormGroupClass!}">
                <input type="hidden" id="clientDataJSON" name="clientDataJSON"/>
                <input type="hidden" id="attestationObject" name="attestationObject"/>
                <input type="hidden" id="publicKeyCredentialId" name="publicKeyCredentialId"/>
                <input type="hidden" id="authenticatorLabel" name="authenticatorLabel"/>
                <input type="hidden" id="transports" name="transports"/>
                <input type="hidden" id="authenticatorAttachment" name="authenticatorAttachment"/>
                <input type="hidden" id="error" name="error"/>
                <@passwordCommons.logoutOtherSessions/>
            </div>
        </form>

        <script type="module">
            <#outputformat "JavaScript">
            import { registerByWebAuthn } from "${url.resourcesPath}/js/webauthnRegister.js";
            const registerButton = document.getElementById('registerWebAuthn');
            registerButton.addEventListener("click", function() {
                const input = {
                    challenge : ${challenge?c},
                    userid : ${userid?c},
                    username : ${username?c},
                    signatureAlgorithms : [<#list signatureAlgorithms as sigAlg>${sigAlg?c},</#list>],
                    rpEntityName : ${rpEntityName?c},
                    rpId : ${rpId?c},
                    attestationConveyancePreference : ${attestationConveyancePreference?c},
                    authenticatorAttachment : ${authenticatorAttachment?c},
                    requireResidentKey : ${requireResidentKey?c},
                    userVerificationRequirement : ${userVerificationRequirement?c},
                    createTimeout : ${createTimeout?c},
                    excludeCredentialIds : ${excludeCredentialIds?c},
                    initLabel : ${msg("webauthn-registration-init-label")?c},
                    initLabelPrompt : ${msg("webauthn-registration-init-label-prompt")?c},
                    errmsg : ${msg("webauthn-unsupported-browser-text")?c}
                };
                // homelab: suppress the "name your passkey" dialog. returnSuccess()
                // treats a null prompt result as "use the default label" and submits.
                window.prompt = () => null;
                registerByWebAuthn(input);
            },  { once: true });
            </#outputformat>
        </script>

            <@buttons.actionGroup horizontal=true>
                <@buttons.button id="registerWebAuthn" label="doRegisterSecurityKey" class=["kcButtonPrimaryClass","kcButtonBlockClass"]/>
                <#if !isSetRetry?has_content && isAppInitiatedAction?has_content>
                    <form class="${properties.kcFormClass!}" action="${url.loginAction}"
                          id="kc-webauthn-settings-form" method="post">
                        <@buttons.button id="cancelWebAuthnAIA" name="cancel-aia" label="doCancel" class=["kcButtonSecondaryClass","kcButtonBlockClass"]/>
                    </form>
                </#if>
            </@buttons.actionGroup>
    </div>
    </#if>
</@layout.registrationLayout>
