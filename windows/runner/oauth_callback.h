#ifndef RUNNER_OAUTH_CALLBACK_H_
#define RUNNER_OAUTH_CALLBACK_H_

#include <windows.h>

constexpr ULONG_PTR kKurakoOAuthCallbackMessage = 0x4B4F4155;
constexpr char kKurakoOAuthCallbackChannel[] =
    "com.tesget.kurako/oauth_callback";

#endif  // RUNNER_OAUTH_CALLBACK_H_
