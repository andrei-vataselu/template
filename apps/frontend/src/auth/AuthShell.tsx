import { FormEvent, useMemo, useState } from "react";
import type { CognitoUser } from "amazon-cognito-identity-js";
import {
  completeNewPassword,
  confirmForgotPassword,
  confirmSignUp,
  forgotPassword,
  resendConfirmation,
  signIn,
  signUp,
  verifyTotp,
  verifyTotpSetup,
} from "./cognitoDirect";

type Mode = "signin" | "signup" | "forgot" | "confirm" | "reset" | "mfa" | "mfa_setup" | "new_password";

type Props = {
  initialMode?: Mode;
  onAuthenticated: () => void;
};

function passwordHints(password: string): string[] {
  const hints: string[] = [];
  if (password.length < 12) hints.push("at least 12 characters");
  if (!/[a-z]/.test(password)) hints.push("a lowercase letter");
  if (!/[A-Z]/.test(password)) hints.push("an uppercase letter");
  if (!/[0-9]/.test(password)) hints.push("a number");
  if (!/[^A-Za-z0-9]/.test(password)) hints.push("a symbol");
  return hints;
}

export function AuthShell({ initialMode = "signin", onAuthenticated }: Props) {
  const [mode, setMode] = useState<Mode>(initialMode);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [password2, setPassword2] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [pendingUser, setPendingUser] = useState<CognitoUser | null>(null);
  const [totpSecret, setTotpSecret] = useState<string | null>(null);

  const title = useMemo(() => {
    switch (mode) {
      case "signup":
        return "Create account";
      case "forgot":
        return "Reset password";
      case "confirm":
        return "Verify email";
      case "reset":
        return "Choose a new password";
      case "mfa":
        return "Authenticator code";
      case "mfa_setup":
        return "Set up authenticator";
      case "new_password":
        return "Set a permanent password";
      default:
        return "Welcome back";
    }
  }, [mode]);

  const subtitle = useMemo(() => {
    switch (mode) {
      case "signup":
        return "Join with your email. We’ll send a verification code over HTTPS via Amazon SES.";
      case "forgot":
        return "Enter your email and we’ll send a reset code from noreply on your domain.";
      case "confirm":
        return "Check your inbox for the verification code.";
      case "reset":
        return "Enter the code from your email and pick a strong password.";
      case "mfa":
        return "Enter the 6-digit code from your authenticator app.";
      case "mfa_setup":
        return "Scan the secret into your authenticator, then enter the code.";
      case "new_password":
        return "Your temporary password must be replaced before continuing.";
      default:
        return "Sign in to continue. Connections stay on HTTPS.";
    }
  }, [mode]);

  async function handleChallenge(result: Awaited<ReturnType<typeof signIn>>) {
    if (result.type === "done") {
      onAuthenticated();
      return;
    }
    if (result.type === "confirm_signup") {
      setEmail(result.email);
      setMode("confirm");
      setInfo("Confirm your email before signing in.");
      return;
    }
    if (result.type === "mfa_totp") {
      setPendingUser(result.user);
      setMode("mfa");
      return;
    }
    if (result.type === "mfa_setup") {
      setPendingUser(result.user);
      setTotpSecret(result.secretCode);
      setMode("mfa_setup");
      return;
    }
    if (result.type === "new_password") {
      setPendingUser(result.user);
      setPassword("");
      setPassword2("");
      setMode("new_password");
    }
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setInfo(null);
    setBusy(true);
    try {
      if (mode === "signin") {
        await handleChallenge(await signIn(email, password));
      } else if (mode === "signup") {
        const hints = passwordHints(password);
        if (hints.length) throw new Error(`Password needs ${hints.join(", ")}`);
        if (password !== password2) throw new Error("Passwords do not match");
        const { userConfirmed } = await signUp(email, password);
        if (userConfirmed) {
          await handleChallenge(await signIn(email, password));
        } else {
          setMode("confirm");
          setInfo("We sent a verification code to your email.");
        }
      } else if (mode === "confirm") {
        await confirmSignUp(email, code);
        setInfo("Email verified. Sign in to continue.");
        setMode("signin");
        setCode("");
      } else if (mode === "forgot") {
        await forgotPassword(email);
        setMode("reset");
        setInfo("Reset code sent. Check your inbox.");
      } else if (mode === "reset") {
        const hints = passwordHints(password);
        if (hints.length) throw new Error(`Password needs ${hints.join(", ")}`);
        if (password !== password2) throw new Error("Passwords do not match");
        await confirmForgotPassword(email, code, password);
        setInfo("Password updated. Sign in with your new password.");
        setMode("signin");
        setCode("");
        setPassword("");
        setPassword2("");
      } else if (mode === "mfa" && pendingUser) {
        await verifyTotp(pendingUser, code);
        onAuthenticated();
      } else if (mode === "mfa_setup" && pendingUser) {
        await verifyTotpSetup(pendingUser, code);
        onAuthenticated();
      } else if (mode === "new_password" && pendingUser) {
        const hints = passwordHints(password);
        if (hints.length) throw new Error(`Password needs ${hints.join(", ")}`);
        if (password !== password2) throw new Error("Passwords do not match");
        await handleChallenge(await completeNewPassword(pendingUser, password));
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong");
    } finally {
      setBusy(false);
    }
  }

  async function onResend() {
    setError(null);
    setBusy(true);
    try {
      await resendConfirmation(email);
      setInfo("Verification code resent.");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not resend code");
    } finally {
      setBusy(false);
    }
  }

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
          <h1>{title}</h1>
          <p className="lede">{subtitle}</p>
        </section>

        <section className="auth-card">
          <form className="auth-form" onSubmit={(e) => void onSubmit(e)}>
            {mode !== "mfa" && mode !== "mfa_setup" && mode !== "new_password" ? (
              <label className="field">
                <span>Email</span>
                <input
                  type="email"
                  autoComplete="email"
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="you@example.com"
                />
              </label>
            ) : null}

            {(mode === "signin" ||
              mode === "signup" ||
              mode === "reset" ||
              mode === "new_password") && (
              <label className="field">
                <span>{mode === "reset" || mode === "new_password" ? "New password" : "Password"}</span>
                <input
                  type="password"
                  autoComplete={mode === "signin" ? "current-password" : "new-password"}
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••••••"
                />
              </label>
            )}

            {(mode === "signup" || mode === "reset" || mode === "new_password") && (
              <label className="field">
                <span>Confirm password</span>
                <input
                  type="password"
                  autoComplete="new-password"
                  required
                  value={password2}
                  onChange={(e) => setPassword2(e.target.value)}
                  placeholder="••••••••••••"
                />
              </label>
            )}

            {(mode === "confirm" || mode === "reset" || mode === "mfa" || mode === "mfa_setup") && (
              <label className="field">
                <span>{mode === "mfa" || mode === "mfa_setup" ? "Authenticator code" : "Email code"}</span>
                <input
                  type="text"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  required
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  placeholder="123456"
                />
              </label>
            )}

            {mode === "mfa_setup" && totpSecret ? (
              <p className="auth-secret mono">Secret: {totpSecret}</p>
            ) : null}

            {error ? <p className="error">{error}</p> : null}
            {info ? <p className="auth-info">{info}</p> : null}

            <button className="btn auth-submit" type="submit" disabled={busy}>
              {busy
                ? "Please wait…"
                : mode === "signin"
                  ? "Sign in"
                  : mode === "signup"
                    ? "Create account"
                    : mode === "forgot"
                      ? "Send reset code"
                      : mode === "confirm"
                        ? "Verify email"
                        : mode === "reset"
                          ? "Update password"
                          : "Continue"}
            </button>
          </form>

          <div className="auth-links">
            {mode === "signin" ? (
              <>
                <button type="button" className="linkish" onClick={() => setMode("signup")}>
                  Create an account
                </button>
                <button type="button" className="linkish" onClick={() => setMode("forgot")}>
                  Forgot password?
                </button>
              </>
            ) : null}
            {mode === "signup" ? (
              <button type="button" className="linkish" onClick={() => setMode("signin")}>
                Already have an account? Sign in
              </button>
            ) : null}
            {mode === "forgot" || mode === "reset" ? (
              <button type="button" className="linkish" onClick={() => setMode("signin")}>
                Back to sign in
              </button>
            ) : null}
            {mode === "confirm" ? (
              <>
                <button type="button" className="linkish" onClick={() => void onResend()} disabled={busy}>
                  Resend code
                </button>
                <button type="button" className="linkish" onClick={() => setMode("signin")}>
                  Back to sign in
                </button>
              </>
            ) : null}
          </div>
        </section>
      </main>
    </div>
  );
}
