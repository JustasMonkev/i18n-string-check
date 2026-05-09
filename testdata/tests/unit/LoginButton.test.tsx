import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { LoginButton } from "../../src/components/LoginButton";

describe("LoginButton", () => {
  it("renders the sign-in copy", () => {
    render(<LoginButton />);

    expect(screen.getByRole("button")).toHaveTextContent("Sign in using biometrics");
  });
});
