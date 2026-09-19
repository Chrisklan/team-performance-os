// Team Performance OS — Abmelden. POST auf /auth/signout, funktioniert ohne JavaScript.

type SignOutButtonProps = {
  label?: string;
  variant?: "quiet" | "primary";
};

export function SignOutButton({
  label = "Abmelden",
  variant = "quiet",
}: SignOutButtonProps) {
  const style =
    variant === "primary"
      ? "bg-accent text-surface font-bold hover:bg-accent/90"
      : "border border-muted text-ink hover:border-accent";
  return (
    <form action="/auth/signout" method="post">
      <button
        type="submit"
        className={`flex h-12 items-center justify-center rounded-md px-4 text-sm transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-accent ${style}`}
      >
        {label}
      </button>
    </form>
  );
}
