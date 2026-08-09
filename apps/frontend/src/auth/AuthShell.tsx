import { useEffect } from "react";
import { beginAuth, type CognitoAuthScreen } from "./cognitoAuth";

type Props = {
  screen: CognitoAuthScreen;
};

/**
 * Branded interstitial — auth itself is Cognito Hosted UI only.
 * We never collect passwords in the app.
 */
export function AuthShell({ screen }: Props) {
  useEffect(() => {
    void beginAuth(screen).catch(() => {
      // beginAuth navigates away on success; surface failures inline
    });
  }, [screen]);

  const label =
    screen === "signup" ? "Create account" : screen === "forgotPassword" ? "Reset password" : "Sign in";

  return (
    <div className="page auth-page">
      <div className="glow" aria-hidden />
      <header className="nav">
        <a className="brand brand-link" href="/">
          template
        </a>
      </header>
      <main className="auth-layout">
        <section className="auth-copy">
          <p className="auth-kicker">Secure access</p>
          <h1>{label}</h1>
          <p className="lede">
            Continuing on Cognito over HTTPS — identity, signup, and password reset stay with Amazon Cognito.
            This app only provides the interface around it.
          </p>
        </section>
        <section className="auth-card">
          <p className="muted">Redirecting to secure Cognito…</p>
          <button
            type="button"
            className="btn auth-submit"
            onClick={() => void beginAuth(screen)}
          >
            Continue
          </button>
          <div className="auth-links">
            {screen !== "login" ? (
              <button type="button" className="linkish" onClick={() => void beginAuth("login")}>
                Sign in instead
              </button>
            ) : null}
            {screen !== "signup" ? (
              <button type="button" className="linkish" onClick={() => void beginAuth("signup")}>
                Create an account
              </button>
            ) : null}
            {screen !== "forgotPassword" ? (
              <button type="button" className="linkish" onClick={() => void beginAuth("forgotPassword")}>
                Forgot password?
              </button>
            ) : null}
          </div>
        </section>
      </main>
    </div>
  );
}
