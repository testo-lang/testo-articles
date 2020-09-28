
#pragma once

#include <string>
#include <vector>

struct App {
	App(const std::vector<std::string>& args);
	void render();

	std::vector<std::string> _args;
};
