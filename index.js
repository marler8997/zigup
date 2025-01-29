document.addEventListener("DOMContentLoaded", function () {
  const os_opts = document.querySelectorAll(".os_opts div");
  let active_os = undefined;

  // initial activation
  // why doing so?
  // for those who disabled javascript, they can still see the content
  document.querySelectorAll(".os").forEach((e) => {
    e.classList.add("hidden");
  });

  document.querySelectorAll(".arch").forEach((e) => {
    e.classList.add("hidden");
  });

  os_opts.forEach((e) => {
    e.addEventListener("click", () => {
      activate_os(e);
    });
  });

  const arch_opts = document.querySelectorAll(".arch_opts div");
  let active_arch = undefined;

  arch_opts.forEach((e) => {
    e.addEventListener("click", () => {
      activate_arch(e);
    });
  });

  const copy_button = document.querySelectorAll(".copy");

  copy_button.forEach((e) => {
    e.addEventListener("click", () => {
      const text = e.parentElement.querySelector("code").innerText;
      navigator.clipboard
        .writeText(text)
        .then(() => {
          e.innerText = "Copied!";
          setTimeout(() => {
            e.innerText = "Copy";
          }, 2000);
        })
        .catch((err) => {
          alert("Failed to copy to clipboard, error: " + err);
        });
    });
  });

  function activate_os(os) {
    if (active_os != undefined) deactivate_os(active_os);
    document
      .getElementsByClassName(os.innerText.toLowerCase())[0]
      .classList.remove("hidden");
    os.classList.add("enabled");
    active_os = os;
  }

  function activate_arch(arch) {
    if (active_arch != undefined) deactivate_arch(active_arch);
    Array.from(document.getElementsByClassName(arch.innerText)).forEach((e) => {
      e.classList.remove("hidden");
    });
    arch.classList.add("enabled");
    active_arch = arch;
  }

  function deactivate_os(os) {
    active_os.classList.remove("enabled");
    document
      .getElementsByClassName(os.innerText.toLowerCase())[0]
      .classList.add("hidden");
  }

  function deactivate_arch(arch) {
    active_arch.classList.remove("enabled");
    Array.from(document.getElementsByClassName(arch.innerText)).forEach((e) => {
      e.classList.add("hidden");
    });
  }

  // defult active
  // linux x86_64
  activate_os(document.getElementsByClassName("os_opts")[0].children[0]);
  activate_arch(document.getElementsByClassName("arch_opts")[0].children[0]);
});
