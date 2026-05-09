export function TemplateDynamic({ name }: { name: string }) {
  const label = `Sign in ${name}`;
  return <span>{label}</span>;
}
