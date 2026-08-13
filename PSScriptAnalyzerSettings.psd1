@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Everything here writes to a CI log, which is the host. Write-Output would put the same text on the
        # pipeline, where a script that returns a value would then return the log with it.
        'PSAvoidUsingWriteHost',

        # Get-MyCertificates returns a collection, and Get-MyCertificate reads as "fetch one".
        'PSUseSingularNouns'
    )
}
