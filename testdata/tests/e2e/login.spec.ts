import { expect, test } from "@playwright/test";

test("login", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("button")).toHaveText("Sign in");
});
