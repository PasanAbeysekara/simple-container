#define _GNU_SOURCE
#include <sched.h>      // For clone() and namespace flags
#include <stdio.h>      // For printf(), perror()
#include <stdlib.h>     // For exit(), clearenv(), setenv()
#include <unistd.h>     // For sethostname(), chroot(), chdir(), execv()
#include <sys/mount.h>  // For mount()
#include <signal.h>     // For SIGCHLD
#include <sys/wait.h>   // For waitpid() - NEW!

#define STACK_SIZE (1024 * 1024) // Define the stack size for the child process
char child_stack[STACK_SIZE];    // Allocate memory for the child process stack

// Function executed in the child process (containerized environment)
int child_func(void *arg) {
    (void)arg;  // Suppress unused warning if not using arg

    printf("=> Inside demo container!\n");

    // Step 1: Make the mount namespace private
    // This ensures that mounts made inside the container are not visible to the host
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        perror("mount: make / private failed");
        exit(EXIT_FAILURE);
    }

    // Set the hostname for the container (UTS namespace)
    // This isolates the hostname from the host system
    if (sethostname("mycontainer", 11) != 0) { // Increased length to 11 to include null terminator in common usage, though 10 works
        perror("sethostname failed");
        exit(EXIT_FAILURE);
    }

    // Change the root directory of the container (chroot jail)
    // This isolates the filesystem of the container. The path '/tmp/mycontainer_root'
    // must exist and contain the necessary binaries (like /bin/sh).
    if (chroot("/tmp/mycontainer_root") != 0) {
        perror("chroot failed");
        exit(EXIT_FAILURE);
    }

    // Change the working directory to the new root (/)
    // This is important after a chroot to ensure subsequent operations
    // are relative to the new root.
    if (chdir("/") != 0) {
        perror("chdir failed");
        exit(EXIT_FAILURE);
    }

    // Mount the proc filesystem inside the container
    // This is required for commands like `ps` to work properly within the container,
    // as process information is typically exposed through /proc.
    if (mount("proc", "/proc", "proc", 0, NULL) != 0) {
        perror("mount /proc failed");
        exit(EXIT_FAILURE);
    }

    // 🚨 Environment cleanup
    // Clear the environment variables inherited from the host to avoid
    // leaking host environment specifics into the container.
    clearenv();

    // Set minimal environment variables for the container
    // PATH: Defines the directories where the shell looks for executable commands.
    // HOME: Sets the home directory for the container's user.
    // TERM: Specifies the terminal type, often /bin/sh is sufficient for basic shells.
    if (setenv("PATH", "/bin:/usr/bin", 1) != 0) { // Added /usr/bin for common binaries
        perror("setenv PATH failed");
        exit(EXIT_FAILURE);
    }
    if (setenv("HOME", "/", 1) != 0) {
        perror("setenv HOME failed");
        exit(EXIT_FAILURE);
    }
    if (setenv("TERM", "xterm", 1) != 0) { // More standard terminal type
        perror("setenv TERM failed");
        exit(EXIT_FAILURE);
    }

    // Arguments for the executable. /bin/sh is common as a container's init process.
    char *const args[] = { "/bin/sh", NULL };
    
    // Execute the container's init process (/bin/sh)
    // `execv` replaces the current process image with a new one.
    // This is crucial because after setting up namespaces, chroot, etc.,
    // we want to execute the actual container workload. If successful,
    // this function does not return.
    execv(args[0], args);

    // If execv fails, it means the command '/bin/sh' could not be executed.
    // This usually indicates that /bin/sh doesn't exist in the new root
    // or there are permission issues.
    perror("execv failed");
    return 1; // Return an error code if execv fails
}

int main() {
    printf("=> Starting the container launcher\n");

    // Define the namespaces to isolate
    // CLONE_NEWUTS: Isolate hostname and domain name.
    // CLONE_NEWPID: Isolate process IDs (PID namespace), giving the child its own PID 1.
    // CLONE_NEWNS: Isolate mount points (mount namespace), allowing container to have its own filesystem view.
    // CLONE_NEWNET: Isolate network configuration (network namespace), providing a separate network stack.
    // SIGCHLD: Ensures the parent process receives a SIGCHLD signal when the child exits,
    //         allowing `waitpid` to reap the child and prevent a zombie process.
    int flags = CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWNET | SIGCHLD; // Removed duplicate CLONE_NEWUTS

    // Create a new process with the specified namespaces
    // `child_stack + STACK_SIZE` points to the top of the allocated stack,
    // as stacks typically grow downwards on Linux.
    pid_t pid = clone(child_func, child_stack + STACK_SIZE, flags, NULL);

    // Check if clone() failed
    if (pid == -1) {
        perror("clone failed");
        exit(EXIT_FAILURE);
    }

    printf("=> Child PID: %d\n", pid); // Informative output

    // Wait for the child process (container) to finish
    // `waitpid` with `0` as options blocks until the child process changes state.
    // `NULL` for status argument means we don't care about the child's exit status.
    if (waitpid(pid, NULL, 0) == -1) {
        perror("waitpid failed");
        exit(EXIT_FAILURE);
    }
    
    // Unmount /proc from the container's root after the container exits
    // This is important to clean up the mount point after the container is done.
    // Note: This umount happens in the parent after the child (which performed the mount)
    // has exited. This works because the parent and child initially share the mount namespace
    // until CLONE_NEWNS is used, and the mount within the child becomes specific to its
    // new mount namespace. However, unmounting here in the parent is generally for cleanup
    // if the parent's mount namespace was *also* affected or to ensure host cleanup
    // if the container didn't properly unmount (e.g., if execv failed).
    // In a production container system, more sophisticated mount management is used.
    if (umount2("/tmp/mycontainer_root/proc", MNT_DETACH) != 0 && umount2("/tmp/mycontainer_root", MNT_DETACH) != 0) {
        // Attempt to unmount /proc and the root itself (in case child didn't cleanup or exec failed)
        // MNT_DETACH allows lazy unmount if busy
        perror("umount failed (may be okay if child cleaned up)");
    }


    printf("=> Container exited\n");
    return 0;
}

