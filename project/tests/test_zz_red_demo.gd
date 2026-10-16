extends GutTest

func test_deliberate_failure():
	assert_eq(1, 2, "deliberate failure for CI red demo")
