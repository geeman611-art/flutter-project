package com.flutter.gradle.tasks

import org.gradle.api.DefaultTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.TaskAction

/**
 * A generic task that prints a message deferred until execution time.
 * It takes an input of type [T] and a closure to generate the message.
 *
 * @param T The type of the input used to generate the message.
 */
abstract class PrintTaskDeferred<T> : DefaultTask() {
    /**
     * The input data used by the [messageClosure] to generate the output.
     */
    @get:Input
    abstract var closureInput: T

    /**
     * A closure that takes the [closureInput] and returns the string to be printed.
     */
    @get:Input
    abstract var messageClosure: (input: T) -> String

    /**
     * The action executed by the task, which prints the result of [messageClosure].
     */
    @TaskAction
    fun run() {
        println(messageClosure(closureInput))
    }
}
