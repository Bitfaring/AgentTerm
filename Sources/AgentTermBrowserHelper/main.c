// The helper app of the Mac app's browser (#76): every process of Chromium's
// that is not the app itself (a page's renderer, the GPU, the network) runs
// this, from "<App> Helper.app" and its variants in the app's Frameworks
// folder.
#include "AgentTermCEF.h"

int main(int argc, char **argv) { return atc_helper_main(argc, argv); }
