extends GutTest

# Smoke test to confirm the GUT harness runs headless.

func test_gut_harness_runs():
	assert_eq(2 + 2, 4, "arithmetic should work")

func test_true_is_true():
	assert_true(true, "true should be true")
